#!/usr/bin/env bash
# Gate integrity: detects a pull request that weakens the Quality Gate
# (SchoolEngine/.github#22). Copied as is into every SchoolEngine repository
# and run by .github/workflows/gate-integrity.yml (pull_request_target), from
# the default branch: a PR is never judged by its own copy of this script.
#
# Every file of the PR is untrusted DATA: it is extracted with `git cat-file`,
# parsed by yq, jq and Python, never executed, and any text taken from it is
# escaped before it reaches a workflow command (annotations) or is printed
# between ::stop-commands:: markers (diffs, files).
#
# Usage:
#   gate-integrity.sh ci <base-ref> <head-ref>     from the repository root
#   gate-integrity.sh check <base-dir> <head-dir>  two extracted trees (tests)
#
# Environment:
#   PR_JSON_FILE           the PR as returned by GET /repos/{repo}/pulls/{n}
#                          (body: the `## Gate change` section; user: the
#                          author). Without it no gate change is accepted and
#                          action SHAs are compared strictly.
#   GATE_INTEGRITY_TODAY   YYYY-MM-DD, tests only
# Requires bash 4+, git, yq (v4), jq and python3 (tomllib, 3.11 or later).
#
# Two kinds of findings (CI.md, "Gate integrity"):
# - hard: never accepted;
# - gate change: accepted only when the PR body has a `## Gate change`
#   section with a justification of at least 20 letters or digits, HTML
#   comments removed. The approval is the double agent review (code and
#   security) recorded on the PR, not this script.
set -euo pipefail

readonly COMMON_JOBS=(pr-conventions gitleaks actionlint lint-yaml-markdown osv-scanner)
readonly GATE_JOB="quality-gate"
readonly GATE_NAME="Quality Gate"
# shellcheck disable=SC2016  # a literal GitHub expression, not a shell one
readonly GATE_IF='${{ !cancelled() }}'
readonly CI_FILE=".github/workflows/ci.yml"
readonly INTEGRITY_FILE=".github/workflows/gate-integrity.yml"
readonly INTEGRITY_SCRIPT=".github/scripts/gate-integrity.sh"
readonly ACTIONS_DIR=".github/actions"
readonly DEPENDABOT="dependabot[bot]"
readonly MAX_IGNORE_DAYS=180
readonly MIN_JUSTIFICATION=20
readonly DATE_RE='[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])'

hard=0
gate_changes=0
today="${GATE_INTEGRITY_TODAY:-$(date -u +%F)}"
horizon=$(python3 -I -c 'import datetime, sys
print(datetime.date.fromisoformat(sys.argv[1]) + datetime.timedelta(days=int(sys.argv[2])))' "$today" "$MAX_IGNORE_DAYS")
author=""
[[ -z "${PR_JSON_FILE:-}" ]] || author=$(jq -r '.user.login // ""' "$PR_JSON_FILE")

# --- Output -----------------------------------------------------------------

# Text from the PR inside a workflow command: % CR LF encoded as the runner
# expects, and `::` broken so it can never open a command of its own.
escape() {
  local s=$1
  s=${s//%/%25}
  s=${s//$'\r'/%0D}
  s=${s//$'\n'/%0A}
  s=${s//::/: :}
  printf '%s' "$s"
}

hard_error() {
  echo "::error::$(escape "$1")"
  hard=$((hard + 1))
}

gate_change() {
  echo "::warning::$(escape "Gate change: $1")"
  gate_changes=$((gate_changes + 1))
}

notice() { echo "::notice::$(escape "$1")"; }

# Prints text that holds PR content (a diff, a file) with workflow commands
# disabled, so that no line of it can run as one.
untrusted() {
  local token
  token=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
  echo "::stop-commands::$token"
  printf '%s\n' "$1"
  echo "::$token::"
}

# diff -u of two files, printed through `untrusted` when they differ.
# Fails when they differ.
show_diff() {
  local out
  out=$(diff -u --label "$1" --label "$2" "$3" "$4") && return 0
  untrusted "$out"
  return 1
}

# The first document only: a second one is refused by check_workflow_rules.
yaml_json() { yq -o json 'select(document_index == 0)' "$1"; }

toml_json() {
  python3 -I -c 'import json, sys, tomllib
with open(sys.argv[1], "rb") as f:
    print(json.dumps(tomllib.load(f), default=str))' "$1"
}

# A workflow (JSON) as compared with the base branch. Action SHAs are ignored
# only in a Dependabot PR, and only when the action itself is unchanged
# (`owner/repo@<sha>` keeps the owner and the repository).
normalized() {
  jq -S --arg author "$author" --arg bot "$DEPENDABOT" '
    if $author == $bot then
      walk(if type == "object" and (.uses | type) == "string"
           then .uses |= sub("@[0-9a-f]{40}$"; "@<sha>") else . end)
    else . end' <<<"$1"
}

# --- The justification of a gate change -------------------------------------

# Number of letters and digits in the `## Gate change` section of the PR
# body, HTML comments removed first (an unterminated one runs to the end).
justification_length() {
  [[ -n "${PR_JSON_FILE:-}" ]] || { echo 0; return 0; }
  python3 -I -c 'import json, re, sys
with open(sys.argv[1], encoding="utf-8") as f:
    body = (json.load(f).get("body") or "").replace("\r", "")
body = re.sub(r"<!--.*?(?:-->|\Z)", "", body, flags=re.S)
m = re.search(r"^##[ \t]+Gate change[ \t]*\n(.*?)(?=^#{1,2}[ \t]|\Z)", body, flags=re.M | re.S)
print(sum(c.isalnum() for c in m.group(1)) if m else 0)' "$PR_JSON_FILE"
}

# --- ci.yml -----------------------------------------------------------------

# The keys outside `jobs`, which change how every job runs. Tool versions and
# their sha256 are checked by check_tool_pins instead.
top_keys() {
  jq -S '{name, on, permissions, defaults, concurrency,
          env: ((.env // {}) | with_entries(select(.key | test("_(VERSION|SHA256)$") | not)))}' <<<"$1"
}

gate_job() {
  normalized "$1" | jq -S --arg job "$2" '.jobs[$job] | if $job == "quality-gate" then del(.needs) else . end'
}

has_job() { jq -e --arg job "$2" '.jobs | has($job)' <<<"$1" >/dev/null; }

# `*_VERSION` and `*_SHA256` of ci.yml: well formed, never downgraded, and a
# tool's version and sha256 change together. One JSON string per finding.
check_tool_pins() {
  local base=$1 head=$2 finding
  while IFS= read -r finding; do
    hard_error "$CI_FILE env: $(jq -r '.' <<<"$finding")."
  done < <(jq -c --argjson b "$base" '
    def version_ok: test("^[0-9]+(\\.[0-9]+){1,3}$");
    def parts: split(".") | map(tonumber);
    ($b.env // {} | map_values(tostring)) as $be
    | (.env // {} | map_values(tostring)) as $he
    | ( ($he | to_entries[] | select(.key | test("_VERSION$")) | .key as $k | .value as $v
         | if ($v | version_ok | not) then "\($k) \($v | tojson) is not a version (digits and dots)"
           elif ($be[$k] // "" | version_ok) and (($v | parts) < ($be[$k] | parts))
           then "\($k) downgraded from \($be[$k]) to \($v)"
           else empty end),
        ($he | to_entries[] | select(.key | test("_SHA256$"))
         | select(.value | test("^[0-9a-f]{64}$") | not) | "\(.key) is not a sha256 (64 lowercase hex digits)"),
        ($he | keys[] | select(test("_VERSION$")) | sub("_VERSION$"; "") as $t
         | select(($he["\($t)_SHA256"] != null) and ($be["\($t)_VERSION"] != null) and ($be["\($t)_SHA256"] != null))
         | select(($he["\($t)_VERSION"] != $be["\($t)_VERSION"]) != ($he["\($t)_SHA256"] != $be["\($t)_SHA256"]))
         | "\($t)_VERSION and \($t)_SHA256 must change together") )
    | tojson' <<<"$head")
}

check_ci() {
  local base_file=$1 head_file=$2 head base='{}' job missing coe
  if [[ ! -f "$head_file" ]]; then
    hard_error "$CI_FILE is missing."
    return 0
  fi
  head=$(yaml_json "$head_file")
  [[ ! -f "$base_file" ]] || base=$(yaml_json "$base_file")

  for job in "${COMMON_JOBS[@]}" "$GATE_JOB"; do
    has_job "$head" "$job" || hard_error "Mandatory job '$job' is missing from $CI_FILE."
  done
  if has_job "$head" "$GATE_JOB"; then
    [[ "$(jq -r --arg job "$GATE_JOB" '.jobs[$job].name // ""' <<<"$head")" == "$GATE_NAME" ]] \
      || hard_error "Job '$GATE_JOB' must be named exactly '$GATE_NAME' (the required check)."
    [[ "$(jq -r --arg job "$GATE_JOB" '.jobs[$job].if // ""' <<<"$head")" == "$GATE_IF" ]] \
      || hard_error "The 'if:' of '$GATE_JOB' must be exactly $GATE_IF (a skipped required check passes)."
    missing=$(jq -r --arg job "$GATE_JOB" '
      (.jobs[$job].needs // [] | if type == "string" then [.] else . end) as $needs
      | [.jobs | keys[] | select(. != $job and (. as $j | $needs | index($j) | not))] | join(", ")' <<<"$head")
    [[ -z "$missing" ]] || hard_error "Not in the 'needs:' of '$GATE_JOB', so blocking nothing: $missing."
  fi

  coe=$(jq -r '[.jobs | paths | select(.[-1] == "continue-on-error") | map(tostring) | join(".")] | join(", ")' <<<"$head")
  [[ -z "$coe" ]] || hard_error "continue-on-error is forbidden in $CI_FILE (a failing job would pass the gate): $coe."

  check_tool_pins "$base" "$head"

  if [[ ! -f "$base_file" ]]; then
    notice "No $CI_FILE on the base branch: base comparison skipped."
    return 0
  fi

  if ! show_diff "base: $CI_FILE outside jobs" "pr: $CI_FILE outside jobs" \
      <(top_keys "$base") <(top_keys "$head"); then
    gate_change "$CI_FILE changed outside 'jobs' (name, on, permissions, defaults, concurrency or env; diff above)."
  fi

  for job in $(jq -r --arg gate "$GATE_JOB" '.jobs | keys[] | select(. != $gate)' <<<"$base"); do
    has_job "$head" "$job" || gate_change "job '$job' of the base branch was removed."
  done

  for job in "${COMMON_JOBS[@]}" "$GATE_JOB"; do
    if has_job "$base" "$job" && has_job "$head" "$job" \
        && ! show_diff "base: $job" "pr: $job" <(gate_job "$base" "$job") <(gate_job "$head" "$job"); then
      gate_change "the definition of job '$job' changed (diff above)."
    fi
  done
}

# --- Every workflow ---------------------------------------------------------

list_files() {
  [[ -d "$1/$2" ]] || return 0
  (cd "$1" && find "$2" -type f -print | sort)
}

list_workflows() {
  [[ -d "$1/.github/workflows" ]] || return 0
  (cd "$1" && find .github/workflows -maxdepth 1 -type f \( -name '*.yml' -o -name '*.yaml' \) -print | sort)
}

# Rules that hold for every workflow file of the PR.
check_workflow_rules() {
  local path=$1 file=$2 json found
  found=$(yq ea '[.] | length' "$file")
  if [[ "$found" != "1" ]]; then
    hard_error "$path: exactly one YAML document expected, found $found."
    return 0
  fi
  found=$(yq '[.. | select(tag == "!!map") | select((keys | length) != (keys | unique | length))] | length' "$file")
  [[ "$found" == "0" ]] || hard_error "$path: duplicate keys in a mapping (the last one silently wins)."
  found=$(yq '[.. | select(kind == "alias" or anchor != "" or ((path | length) > 0 and (path | .[-1]) == "<<"))] | length' "$file")
  [[ "$found" == "0" ]] || hard_error "$path: YAML anchors, aliases and merge keys are forbidden (they hide a change)."
  json=$(yaml_json "$file")

  jq -e 'type == "object" and has("permissions")' <<<"$json" >/dev/null \
    || hard_error "$path: a top-level 'permissions:' is required (least privilege)."

  found=$(jq -r '
    [paths(type == "string") as $p | select($p[-1] == "shell") | getpath($p)
     | select(IN("bash", "sh", "pwsh", "powershell", "python", "cmd") | not)] | unique | map(tojson) | join(", ")' <<<"$json")
  [[ -z "$found" ]] || hard_error "$path: custom shell forbidden (a shell template can turn every step into a no-op): $found."

  found=$(jq -r '[.jobs // {} | to_entries[] | select((.value.name // "") | tostring | contains("${{")) | .key] | join(", ")' <<<"$json")
  [[ -z "$found" ]] || hard_error "$path: a job name built from an expression could take a required check's name: $found."

  found=$(jq -r --arg ci "$CI_FILE" --arg integrity "$INTEGRITY_FILE" --arg path "$path" '
    [.jobs // {} | to_entries[]
     | ((.value.name // .key) | tostring | ascii_downcase) as $name
     | select((($name | contains("quality gate")) and ($path != $ci or .key != "quality-gate"))
           or (($name | contains("gate integrity")) and ($path != $integrity or .key != "gate-integrity")))
     | .key] | join(", ")' <<<"$json")
  [[ -z "$found" ]] || hard_error "$path: job name reserved for a required check (Quality Gate, Gate integrity): $found."

  # gate-integrity.yml is compared with the base branch instead: any change
  # to it is a gate change.
  [[ "$path" != "$INTEGRITY_FILE" ]] || return 0
  found=$(jq -r '
    (.on // {}) | (if type == "string" then [.] elif type == "array" then . else keys end)
    | map(select(. == "pull_request_target" or . == "workflow_run")) | join(", ")' <<<"$json")
  [[ -z "$found" ]] || hard_error "$path: trigger forbidden outside $INTEGRITY_FILE (it runs with the base repository's trust): $found."

  found=$(jq -r '
    [(.permissions // empty), (.jobs // {} | .[] | .permissions // empty)]
    | map(if type == "string" then select(. == "write-all")
          else to_entries[] | select(.value == "write") | .key end)
    | unique | join(", ")' <<<"$json")
  [[ -z "$found" ]] || hard_error "$path: write permission forbidden (a job could set statuses, labels or code): $found."
}

# How a workflow is compared with the base branch: gate-integrity.yml always
# strictly, the others through `normalized`.
comparable() {
  if [[ "$1" == "$INTEGRITY_FILE" ]]; then
    yaml_json "$2" | jq -S '.'
  else
    normalized "$(yaml_json "$2")"
  fi
}

check_workflows() {
  local base_dir=$1 head_dir=$2 path
  while IFS= read -r path; do
    check_workflow_rules "$path" "$head_dir/$path"
    [[ "$path" != "$CI_FILE" ]] || continue
    if [[ ! -f "$base_dir/$path" ]]; then
      gate_change "new workflow $path (a workflow can report checks and act on the repository)."
      untrusted "$(cat "$head_dir/$path")"
    elif ! show_diff "base: $path" "pr: $path" \
        <(comparable "$path" "$base_dir/$path") <(comparable "$path" "$head_dir/$path"); then
      gate_change "workflow $path changed (diff above)."
    fi
  done < <(list_workflows "$head_dir")

  while IFS= read -r path; do
    [[ ! -f "$head_dir/$path" ]] || continue
    if [[ "$path" == "$INTEGRITY_FILE" ]]; then
      hard_error "$INTEGRITY_FILE was removed: it runs the required 'Gate integrity' check."
    else
      notice "Workflow $path was removed by this PR."
    fi
  done < <(list_workflows "$base_dir")

  if [[ ! -f "$head_dir/$INTEGRITY_SCRIPT" ]]; then
    hard_error "$INTEGRITY_SCRIPT was removed: it is the checker of the 'Gate integrity' check."
  elif [[ -f "$base_dir/$INTEGRITY_SCRIPT" ]] && ! cmp -s "$base_dir/$INTEGRITY_SCRIPT" "$head_dir/$INTEGRITY_SCRIPT"; then
    gate_change "$INTEGRITY_SCRIPT changed (once merged, it judges the next PRs)."
  fi

  # Local actions run inside the jobs that use them, common jobs included.
  while IFS= read -r path; do
    if [[ ! -f "$head_dir/$path" ]]; then
      gate_change "local action file $path was removed."
    elif [[ ! -f "$base_dir/$path" ]]; then
      gate_change "local action file $path was added."
      untrusted "$(cat "$head_dir/$path")"
    elif ! show_diff "base: $path" "pr: $path" "$base_dir/$path" "$head_dir/$path"; then
      gate_change "local action file $path changed (diff above)."
    fi
  done < <({ list_files "$base_dir" "$ACTIONS_DIR"; list_files "$head_dir" "$ACTIONS_DIR"; } | sort -u)
}

# --- The ignore files (ADR-014) ---------------------------------------------

# Why an expiry date is not acceptable, or nothing.
date_problem() {
  local date=$1
  if [[ ! "$date" =~ ^$DATE_RE$ ]]; then
    echo "no valid expiry date (YYYY-MM-DD)"
  elif [[ "$date" < "$today" ]]; then
    echo "expired on $date: remove the ignore or renew it with a new justification"
  elif [[ "$date" > "$horizon" ]]; then
    echo "expiry $date is more than $MAX_IGNORE_DAYS days ahead (latest $horizon)"
  fi
}

# Number of letters and digits of a justification.
letters() {
  local s=${1//[^[:alnum:]]/}
  echo "${#s}"
}

# "<justification> expires: YYYY-MM-DD".
check_expiring_text() {
  local where=$1 text=$2 problem
  if [[ ! "$text" =~ ^(.*)expires:[[:space:]]*([0-9-]+)[[:space:]]*$ ]]; then
    hard_error "$where: needs a justification ending with 'expires: YYYY-MM-DD'."
    return 0
  fi
  [[ "$(letters "${BASH_REMATCH[1]}")" -ge "$MIN_JUSTIFICATION" ]] \
    || hard_error "$where: the justification needs at least $MIN_JUSTIFICATION letters or digits."
  problem=$(date_problem "${BASH_REMATCH[2]}")
  [[ -z "$problem" ]] || hard_error "$where: $problem."
}

check_gitleaksignore() {
  local file=$1 line previous="" n=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    n=$((n + 1))
    line=${line%$'\r'}
    [[ "$line" =~ ^[[:space:]]*$ ]] && continue
    if [[ "$line" =~ ^[[:space:]]*# ]]; then
      previous=$line
      continue
    fi
    check_expiring_text ".gitleaksignore line $n" "${previous#*#}"
    previous=""
  done <"$file"
}

check_gitleaks_toml() {
  local file=$1 json description
  json=$(toml_json "$file")
  jq -e '.extend.useDefault == true' <<<"$json" >/dev/null \
    || gate_change ".gitleaks.toml does not extend the default rules ([extend] useDefault = true)."
  jq -e '(.extend.disabledRules // []) | length == 0' <<<"$json" >/dev/null \
    || gate_change ".gitleaks.toml disables default rules: $(jq -c '.extend.disabledRules' <<<"$json")."
  # One JSON string per line, decoded after the read: a description may hold
  # newlines.
  while IFS= read -r description; do
    description=$(jq -r '.' <<<"$description")
    check_expiring_text ".gitleaks.toml allowlist '${description:-<no description>}'" "$description"
  done < <(jq -c '
    ([.allowlist // empty] + (.allowlists // [])
     + [.rules[]? | (.allowlist // empty), (.allowlists // [])[]])
    | .[] | .description // ""' <<<"$json")
}

check_osv_toml() {
  local path=$1 file=$2 json entry what reason until problem
  json=$(toml_json "$file")
  while IFS= read -r entry; do
    what=$(jq -r '.what' <<<"$entry")
    reason=$(jq -r '.reason' <<<"$entry")
    until=$(jq -r '.until' <<<"$entry")
    [[ "$(letters "$reason")" -ge "$MIN_JUSTIFICATION" ]] \
      || hard_error "$path: $what needs a 'reason' of at least $MIN_JUSTIFICATION letters or digits."
    problem=$(date_problem "$until")
    [[ -z "$problem" ]] || hard_error "$path: $what: $problem ('ignoreUntil' or 'effectiveUntil')."
  done < <(jq -c '
    def day: (. // "") | tostring | .[0:10];
    [ (.IgnoredVulns // [])[]
      | {what: "IgnoredVulns \(.id // "<no id>")", reason: (.reason // ""), until: (.ignoreUntil | day)} ]
    + [ (.PackageOverrides // [])[]
      | select(.ignore == true or .vulnerability.ignore == true or .license.ignore == true)
      | {what: "PackageOverrides \(.name // "<no name>")", reason: (.reason // ""), until: (.effectiveUntil | day)} ]
    | .[]' <<<"$json")
}

# Directories never scanned for osv-scanner.toml: dependencies and build
# output, not the repository's own configuration.
readonly SKIPPED_DIR_RE='(^|/)(\.git|node_modules|\.dart_tool|build|vendor)/'

list_ignores() {
  (cd "$1" && find . -type f \( -name osv-scanner.toml -o -path ./.gitleaks.toml -o -path ./.gitleaksignore \) -print \
   | sed 's|^\./||' | { grep -Ev "$SKIPPED_DIR_RE" || true; } | sort)
}

check_ignores() {
  local base_dir=$1 head_dir=$2 path base_file
  while IFS= read -r path; do
    [[ -f "$head_dir/$path" ]] || notice "$path was removed by this PR."
  done < <(list_ignores "$base_dir")

  while IFS= read -r path; do
    if [[ ! -f "$base_dir/$path" ]] || ! cmp -s "$base_dir/$path" "$head_dir/$path"; then
      base_file=/dev/null
      [[ ! -f "$base_dir/$path" ]] || base_file="$base_dir/$path"
      show_diff "base: $path" "pr: $path" "$base_file" "$head_dir/$path" || true
    fi
    case "$path" in
      .gitleaksignore) check_gitleaksignore "$head_dir/$path" ;;
      .gitleaks.toml) check_gitleaks_toml "$head_dir/$path" ;;
      *) check_osv_toml "$path" "$head_dir/$path" ;;
    esac
  done < <(list_ignores "$head_dir")
}

# --- Entry points -----------------------------------------------------------

# The files this checker reads, from a commit into a directory. Entries are
# NUL separated (a file name may hold any character); only blobs are read.
extract() {
  local ref=$1 dir=$2 entry meta path
  while IFS= read -r -d '' entry; do
    meta=${entry%%$'\t'*}
    path=${entry#*$'\t'}
    [[ "$meta" == *" blob "* ]] || continue
    case "$path" in
      .github/workflows/*.yml | .github/workflows/*.yaml | "$INTEGRITY_SCRIPT" | "$ACTIONS_DIR"/* | .gitleaks.toml | .gitleaksignore) ;;
      osv-scanner.toml | */osv-scanner.toml) [[ ! "$path" =~ $SKIPPED_DIR_RE ]] || continue ;;
      *) continue ;;
    esac
    # git refuses such paths; never write outside the directory regardless.
    if [[ "/$path/" == *"/../"* || "/$path/" == *"/./"* || "/$path/" == *"/.git/"* || "$path" == /* ]]; then
      hard_error "Refused path in the tree: $path."
      continue
    fi
    mkdir -p "$dir/$(dirname "$path")"
    git cat-file blob "${meta##* }" >"$dir/$path"
  done < <(git ls-tree -r -z "$ref")
}

check_trees() {
  echo "== $CI_FILE against the base branch"
  check_ci "$1/$CI_FILE" "$2/$CI_FILE"
  echo "== Workflows, local actions and the checker"
  check_workflows "$1" "$2"
  echo "== Ignore files (gitleaks, osv-scanner)"
  check_ignores "$1" "$2"
}

run_ci() {
  WORK_TMP=$(mktemp -d)
  trap 'rm -rf "$WORK_TMP"' EXIT
  mkdir "$WORK_TMP/base" "$WORK_TMP/head"
  extract "$1" "$WORK_TMP/base"
  extract "$2" "$WORK_TMP/head"
  check_trees "$WORK_TMP/base" "$WORK_TMP/head"
}

verdict() {
  local length
  if [[ "$gate_changes" -gt 0 ]]; then
    length=$(justification_length)
    if [[ "$length" -ge "$MIN_JUSTIFICATION" ]]; then
      echo "::warning::$gate_changes gate change(s) justified in the '## Gate change' section: the double agent review (code and security) recorded on the PR is the approval."
      [[ -z "${GITHUB_STEP_SUMMARY:-}" ]] \
        || echo "**Gate change**: $gate_changes change(s) to the Quality Gate, justified in the PR body. The double agent review (code and security) recorded on the PR is the approval; Céline's explicit go is required to merge." >>"$GITHUB_STEP_SUMMARY"
    else
      echo "::error::$gate_changes gate change(s) without a justification: add a '## Gate change' section of at least $MIN_JUSTIFICATION letters or digits, HTML comments excluded (CI.md, Gate integrity)."
      hard=$((hard + 1))
    fi
  fi
  if [[ "$hard" -gt 0 ]]; then
    echo "Gate integrity failed."
    return 1
  fi
  echo "Gate integrity passed."
}

main() {
  case "${1:-}" in
    ci) run_ci "${2:?base ref}" "${3:?head ref}" ;;
    check) check_trees "${2:?base dir}" "${3:?head dir}" ;;
    *) echo "usage: gate-integrity.sh ci <base-ref> <head-ref> | check <base-dir> <head-dir>" >&2; exit 2 ;;
  esac
  verdict
}

main "$@"
