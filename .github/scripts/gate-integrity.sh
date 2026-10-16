#!/usr/bin/env bash
# Gate integrity: detects a pull request that weakens the Quality Gate
# (SchoolEngine/.github#22). Copied as is into every SchoolEngine repository
# and run by .github/workflows/gate-integrity.yml (pull_request_target), from
# the DEFAULT branch: a PR is never judged by its own copy of this script.
#
# Every file of the PR is untrusted DATA: it is extracted with `git cat-file`,
# parsed by yq, jq and Python's tomllib, never executed, and any text taken
# from it is escaped before it reaches a workflow command (annotations) or is
# printed between ::stop-commands:: markers (diffs).
#
# Usage:
#   gate-integrity.sh ci <base-ref> <head-ref>     from the repository root
#   gate-integrity.sh check <base-dir> <head-dir>  two extracted trees (tests)
#
# Environment (all optional; without them no gate change can be approved):
#   PR_JSON_FILE           the PR as returned by GET /repos/{repo}/pulls/{n}
#   PR_EVENTS_FILE         its issue events (GET /repos/{repo}/issues/{n}/events)
#   PR_ACTION              the pull_request_target activity type
#   GATE_CHANGE_APPROVERS  logins allowed to approve, comma or space separated
#   GATE_INTEGRITY_TODAY   YYYY-MM-DD, tests only
# Requires bash 4+, git, yq (v4), jq and python3 (tomllib, 3.11 or later).
#
# Two kinds of findings (CI.md, "Gate integrity"):
# - hard: never accepted;
# - gate change: accepted only when an approver listed in
#   GATE_CHANGE_APPROVERS, who is not the PR author, applied the
#   `gate-change-approved` label to the current state of the PR, and the PR
#   body has a non-empty `## Gate change` section.
set -euo pipefail

readonly COMMON_JOBS=(pr-conventions gitleaks actionlint lint-yaml-markdown osv-scanner)
readonly GATE_JOB="quality-gate"
readonly GATE_NAME="Quality Gate"
# shellcheck disable=SC2016  # a literal GitHub expression, not a shell one
readonly GATE_IF='${{ !cancelled() }}'
readonly CI_FILE=".github/workflows/ci.yml"
readonly INTEGRITY_FILE=".github/workflows/gate-integrity.yml"
readonly INTEGRITY_SCRIPT=".github/scripts/gate-integrity.sh"
readonly APPROVAL_LABEL="gate-change-approved"
readonly ALLOWED_SHELLS=" bash sh pwsh powershell python cmd "
readonly MAX_IGNORE_DAYS=180
readonly MIN_JUSTIFICATION=20
readonly DATE_RE='[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])'

hard=0
gate_changes=0
today="${GATE_INTEGRITY_TODAY:-$(date -u +%F)}"
horizon=$(python3 -I -c 'import datetime, sys
print(datetime.date.fromisoformat(sys.argv[1]) + datetime.timedelta(days=int(sys.argv[2])))' "$today" "$MAX_IGNORE_DAYS")

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

yaml_json() { yq -o json '.' "$1"; }

toml_json() {
  python3 -I -c 'import json, sys, tomllib
with open(sys.argv[1], "rb") as f:
    print(json.dumps(tomllib.load(f), default=str))' "$1"
}

# A workflow (JSON) with the action SHAs replaced: Dependabot bumps them.
normalized() {
  jq -S 'walk(if type == "object" and (.uses | type) == "string"
              then .uses |= sub("@[0-9a-f]{40}$"; "@<sha>") else . end)' <<<"$1"
}

# --- The approval of a gate change ------------------------------------------

gate_change_section() {
  jq -r '.body // ""' "$PR_JSON_FILE" | tr -d '\r' | awk '
    /^##[[:space:]]+Gate change[[:space:]]*$/ { in_section = 1; next }
    in_section && /^##?[[:space:]]/ { in_section = 0 }
    in_section && /[[:alnum:]]/ && !/^[[:space:]]*<!--/ { found = 1 }
    END { exit found ? 0 : 1 }'
}

# Prints the approver and succeeds, or prints why not and fails.
gate_change_approval() {
  local approver author login
  if [[ -z "${PR_JSON_FILE:-}" || -z "${PR_EVENTS_FILE:-}" ]]; then
    echo "no PR metadata"
    return 1
  fi
  if [[ "${PR_ACTION:-}" == "synchronize" ]]; then
    echo "new commits were pushed, which withdraws the approval: an approver re-applies the '$APPROVAL_LABEL' label"
    return 1
  fi
  if ! gate_change_section; then
    echo "the PR body has no '## Gate change' section with a justification"
    return 1
  fi
  approver=$(jq -r --arg label "$APPROVAL_LABEL" --slurpfile pr "$PR_JSON_FILE" '
    if ($pr[0].labels // [] | map(.name) | index($label)) == null then ""
    else [.[] | select(.event == "labeled" and .label.name == $label)] | last | .actor.login // ""
    end' "$PR_EVENTS_FILE")
  author=$(jq -r '.user.login // ""' "$PR_JSON_FILE")
  if [[ -z "$approver" ]]; then
    echo "the '$APPROVAL_LABEL' label is not on the PR"
    return 1
  fi
  if [[ "${approver,,}" == "${author,,}" ]]; then
    echo "the '$APPROVAL_LABEL' label was applied by the PR author ($approver)"
    return 1
  fi
  for login in ${GATE_CHANGE_APPROVERS//,/ }; do
    if [[ "${login,,}" == "${approver,,}" ]]; then
      echo "$approver"
      return 0
    fi
  done
  echo "the '$APPROVAL_LABEL' label was applied by $approver, who is not in GATE_CHANGE_APPROVERS"
  return 1
}

# --- ci.yml -----------------------------------------------------------------

# The keys outside `jobs`, which change how every job runs. Tool versions and
# their sha256 aside: bumped by hand and reviewed as such.
top_keys() {
  jq -S '{name, on, permissions, defaults, concurrency,
          env: ((.env // {}) | with_entries(select(.key | test("_(VERSION|SHA256)$") | not)))}' <<<"$1"
}

gate_job() {
  normalized "$1" | jq -S --arg job "$2" '.jobs[$job] | if $job == "quality-gate" then del(.needs) else . end'
}

has_job() { jq -e --arg job "$2" '.jobs | has($job)' <<<"$1" >/dev/null; }

check_ci() {
  local base_file=$1 head_file=$2 head base job missing coe
  if [[ ! -f "$head_file" ]]; then
    hard_error "$CI_FILE is missing."
    return 0
  fi
  head=$(yaml_json "$head_file")

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

  if [[ ! -f "$base_file" ]]; then
    notice "No $CI_FILE on the base branch: base comparison skipped."
    return 0
  fi
  base=$(yaml_json "$base_file")

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

list_workflows() {
  [[ -d "$1/.github/workflows" ]] || return 0
  (cd "$1" && find .github/workflows -maxdepth 1 -type f \( -name '*.yml' -o -name '*.yaml' \) -print | sort)
}

# Rules that hold for every workflow file of the PR.
check_workflow_rules() {
  local path=$1 file=$2 json found
  found=$(yq '[.. | select(kind == "alias" or anchor != "" or ((path | length) > 0 and (path | .[-1]) == "<<"))] | length' "$file")
  [[ "$found" == "0" ]] || hard_error "$path: YAML anchors, aliases and merge keys are forbidden (they hide a change)."
  json=$(yaml_json "$file")

  found=$(jq -r --arg allowed "$ALLOWED_SHELLS" '
    [paths(type == "string") as $p | select($p[-1] == "shell") | getpath($p)
     | select(. as $s | $allowed | contains(" \($s) ") | not)] | unique | join(", ")' <<<"$json")
  [[ -z "$found" ]] || hard_error "$path: custom shell forbidden (a shell template can turn every step into a no-op): $found."

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

check_workflows() {
  local base_dir=$1 head_dir=$2 path
  while IFS= read -r path; do
    check_workflow_rules "$path" "$head_dir/$path"
    [[ "$path" != "$CI_FILE" ]] || continue
    if [[ ! -f "$base_dir/$path" ]]; then
      gate_change "new workflow $path (a workflow can report checks and act on the repository)."
      untrusted "$(cat "$head_dir/$path")"
    elif ! show_diff "base: $path" "pr: $path" \
        <(normalized "$(yaml_json "$base_dir/$path")") <(normalized "$(yaml_json "$head_dir/$path")"); then
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

list_ignores() {
  (cd "$1" && find . -path ./.git -prune -o -path '*/node_modules' -prune -o \
     \( -name osv-scanner.toml -o -path ./.gitleaks.toml -o -path ./.gitleaksignore \) -type f -print \
   | sed 's|^\./||' | sort)
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
      .github/workflows/*.yml | .github/workflows/*.yaml | "$INTEGRITY_SCRIPT" | .gitleaks.toml | .gitleaksignore | osv-scanner.toml | */osv-scanner.toml) ;;
      *) continue ;;
    esac
    mkdir -p "$dir/$(dirname "$path")"
    git cat-file blob "${meta##* }" >"$dir/$path"
  done < <(git ls-tree -r -z "$ref")
}

check_trees() {
  echo "== $CI_FILE against the base branch"
  check_ci "$1/$CI_FILE" "$2/$CI_FILE"
  echo "== Workflows and the checker"
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
  local approval
  if [[ "$gate_changes" -gt 0 ]]; then
    if approval=$(gate_change_approval); then
      echo "::warning::$(escape "$gate_changes gate change(s) approved by $approval (label '$APPROVAL_LABEL', '## Gate change' section).")"
      [[ -z "${GITHUB_STEP_SUMMARY:-}" ]] \
        || echo "**Gate change**: $gate_changes change(s) to the Quality Gate, approved by $approval with the \`$APPROVAL_LABEL\` label. Double agent review and Céline's explicit approval required before merge." >>"$GITHUB_STEP_SUMMARY"
    else
      echo "::error::$(escape "$gate_changes gate change(s) not approved: $approval (CI.md, Gate integrity).")"
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
