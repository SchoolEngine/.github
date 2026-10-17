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
#                          author). Without it no gate change is accepted.
#   PR_COMMITS_FILE        its commits (GET /repos/{repo}/pulls/{n}/commits,
#                          all pages). Action SHAs are ignored only when the
#                          author and every commit are Dependabot's, signed.
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
# Configuration of the common jobs and of Dependabot: a change to any of them
# is a gate change.
readonly WATCHED_FILES=(.github/actionlint.yaml .github/actionlint.yml .github/dependabot.yml .github/dependabot.yaml
  .yamllint .yamllint.yml .yamllint.yaml .markdownlint-cli2.yaml .markdownlint-cli2.jsonc .markdownlint-cli2.cjs
  .markdownlint.yaml .markdownlint.yml .markdownlint.json .markdownlint.jsonc)
readonly WORKFLOW_KEYS='["name", "run-name", "on", "permissions", "env", "defaults", "concurrency", "jobs"]'
# Triggers whose runs a PR author can cause: no write permission there.
readonly PR_TRIGGERS='["pull_request", "pull_request_target", "pull_request_review", "pull_request_review_comment", "issue_comment", "workflow_run"]'
readonly DEPENDABOT="dependabot[bot]"
readonly MAX_IGNORE_DAYS=180
readonly MIN_JUSTIFICATION=20
readonly DATE_RE='[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])'

hard=0
gate_changes=0
today="${GATE_INTEGRITY_TODAY:-$(date -u +%F)}"
horizon=$(python3 -I -c 'import datetime, sys
print(datetime.date.fromisoformat(sys.argv[1]) + datetime.timedelta(days=int(sys.argv[2])))' "$today" "$MAX_IGNORE_DAYS")
# A Dependabot PR: opened by Dependabot, and every commit authored by it with
# a verified signature (anyone with write access can push to its branch).
dependabot=false
if [[ -n "${PR_JSON_FILE:-}" && -n "${PR_COMMITS_FILE:-}" ]] \
    && [[ "$(jq -r '.user.login // ""' "$PR_JSON_FILE")" == "$DEPENDABOT" ]] \
    && jq -e --arg bot "$DEPENDABOT" 'length > 0 and all(.[]; .author.login == $bot and .commit.verification.verified == true)' \
      "$PR_COMMITS_FILE" >/dev/null; then
  dependabot=true
fi

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

# TOML as JSON, every key lowercased: gitleaks and osv-scanner read keys
# case-insensitively (`[AllowList]` is `[allowlist]`), so the checker must too.
# Keys that differ only by case are refused (exit 1, message on stdout).
toml_json() {
  python3 -I -c 'import json, sys, tomllib
def lower(value, where):
    if isinstance(value, dict):
        out = {}
        for key, item in value.items():
            low = key.lower()
            if low in out:
                print(f"keys that differ only by case: {where}{low}")
                sys.exit(1)
            out[low] = lower(item, f"{where}{low}.")
        return out
    if isinstance(value, list):
        return [lower(item, where) for item in value]
    return value
try:
    with open(sys.argv[1], "rb") as f:
        data = tomllib.load(f)
except tomllib.TOMLDecodeError as error:
    print(f"not valid TOML: {error}")
    sys.exit(1)
print(json.dumps(lower(data, ""), default=str))' "$1"
}

# A workflow (JSON) as compared with the base branch. Action SHAs are ignored
# only in a Dependabot PR (see `dependabot`), and only when the action itself
# is unchanged (`owner/repo@<sha>` keeps the owner and the repository).
normalized() {
  jq -S --argjson dependabot "$dependabot" '
    if $dependabot then
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

# `*_VERSION` and `*_SHA256` of ci.yml: well formed, never downgraded, a
# tool's version and sha256 change together, a sha256 is never dropped while
# its version stays. One JSON string per finding.
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
         | "\($t)_VERSION and \($t)_SHA256 must change together"),
        ($be | keys[] | select(test("_SHA256$")) | . as $k | sub("_SHA256$"; "") as $t
         | select($he[$k] == null and $he["\($t)_VERSION"] != null)
         | "\($k) removed while \($t)_VERSION stays (the download would go unverified)") )
    | tojson' <<<"$head")
  # A new binary is reviewed as such: any sha256 change is a gate change.
  while IFS= read -r finding; do
    gate_change "$CI_FILE env: $finding changed (a different tool binary)."
  done < <(jq -r --argjson b "$base" '($b.env // {}) as $be | (.env // {}) | to_entries[]
    | select((.key | test("_SHA256$")) and $be[.key] != null and ($be[.key] | tostring) != (.value | tostring)) | .key' <<<"$head")
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

  coe=$(jq -r '.jobs as $jobs | [$jobs | paths | select(.[-1] == "continue-on-error")
    | select(. as $p | $jobs | getpath($p) != false) | map(tostring) | join(".")] | join(", ")' <<<"$head")
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

  found=$(jq -r --argjson known "$WORKFLOW_KEYS" '[keys[] | select(. as $k | $known | index($k) | not)] | map(tojson) | join(", ")' <<<"$json")
  [[ -z "$found" ]] || hard_error "$path: unknown top-level key (keys are case-sensitive: 'on', not 'On'): $found."

  found=$(jq -r '
    [(.jobs // {} | .[] | .uses // empty | select(startswith("./"))
        | select((test("^[.]/[.]github/workflows/[^/]+[.]ya?ml$") | not) or contains(".."))),
       (.jobs // {} | .[] | .steps // [] | .[] | .uses // empty | select(startswith("./"))
        | select((startswith("./.github/actions/") | not) or contains("..")))]
    | unique | map(tojson) | join(", ")' <<<"$json")
  [[ -z "$found" ]] || hard_error "$path: local action or workflow outside .github/actions/ or .github/workflows/ (not checked): $found."

  found=$(jq -r '
    [paths(type == "string") as $p | select($p[-1] == "shell") | getpath($p)
     | select(IN("bash", "sh", "pwsh", "powershell", "python", "cmd") | not)] | unique | map(tojson) | join(", ")' <<<"$json")
  [[ -z "$found" ]] || hard_error "$path: custom shell forbidden (a shell template can turn every step into a no-op): $found."

  # An expression in a job name is accepted only as `<literal> (${{ matrix.<key> }})`:
  # the rendered name then always ends with ")" and can never be a required
  # check's exact name, whatever the matrix values. Any other form (several
  # expressions, text around them, format()) could concatenate one.
  found=$(jq -r '[.jobs // {} | to_entries[] | (.value.name // "" | tostring) as $name
    | select($name | contains("${{"))
    | select(($name | test("^[^$]*[(][$][{][{] *matrix[.][A-Za-z0-9_-]+ *[}][}][)]$") | not)
        or ($name | capture("^(?<literal>[^$]*)[(]").literal | ascii_downcase | gsub("^ +| +$"; "")
            | IN("quality gate", "gate integrity")))
    | .key] | join(", ")' <<<"$json")
  [[ -z "$found" ]] || hard_error "$path: an expression in a job name is only accepted as '<name> (\${{ matrix.<key> }})': $found."

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

  local triggers writes
  triggers=$(jq -c '(.on // {}) | if type == "string" then [.] elif type == "array" then . else keys end' <<<"$json")
  writes=$(jq -r '
    [(.permissions // empty), (.jobs // {} | .[] | .permissions // empty)]
    | map(if type == "string" then select(. == "write-all")
          else to_entries[] | select(.value == "write") | .key end)
    | unique | join(", ")' <<<"$json")
  [[ -n "$writes" ]] || return 0
  if [[ "$writes" == *write-all* ]] \
      || jq -e --argjson pr "$PR_TRIGGERS" 'any(.[]; . as $t | $pr | index($t))' <<<"$triggers" >/dev/null; then
    hard_error "$path: write permission forbidden with write-all or on a trigger a PR author can cause ($(jq -r 'join(", ")' <<<"$triggers")): $writes."
  else
    gate_change "$path grants write permissions ($writes) on $(jq -r 'join(", ")' <<<"$triggers")."
  fi
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

  for path in "${WATCHED_FILES[@]}"; do
    if [[ -f "$base_dir/$path" && ! -f "$head_dir/$path" ]]; then
      gate_change "$path was removed (configuration of the common jobs or of Dependabot)."
    elif [[ ! -f "$base_dir/$path" && -f "$head_dir/$path" ]]; then
      gate_change "$path was added (configuration of the common jobs or of Dependabot)."
      untrusted "$(cat "$head_dir/$path")"
    elif [[ -f "$head_dir/$path" ]] && ! show_diff "base: $path" "pr: $path" "$base_dir/$path" "$head_dir/$path"; then
      gate_change "$path changed (configuration of the common jobs or of Dependabot; diff above)."
    fi
  done
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
  local base_file=$1 file=$2 json base='{}' description
  if ! json=$(toml_json "$file"); then
    hard_error ".gitleaks.toml: $json."
    return 0
  fi
  if [[ -f "$base_file" ]]; then
    base=$(toml_json "$base_file") || base='{}'
  fi
  jq -e '.extend | has("path") or has("url")' <<<"$json" >/dev/null 2>&1 \
    && hard_error ".gitleaks.toml: [extend] path or url is forbidden (the extended file is not checked)."
  jq -e '.extend.usedefault == true' <<<"$json" >/dev/null \
    || gate_change ".gitleaks.toml does not extend the default rules ([extend] useDefault = true)."
  jq -e '(.extend.disabledrules // []) | length == 0' <<<"$json" >/dev/null \
    || gate_change ".gitleaks.toml disables default rules: $(jq -c '.extend.disabledrules' <<<"$json")."
  # A rule with the id of a default rule replaces it: any rule added or
  # changed is reviewed as a gate change.
  if ! show_diff "base: .gitleaks.toml rules" "pr: .gitleaks.toml rules" \
      <(jq -S '.rules // []' <<<"$base") <(jq -S '.rules // []' <<<"$json"); then
    gate_change ".gitleaks.toml rules added or changed (a rule can replace a default one; diff above)."
  fi
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
  if ! json=$(toml_json "$file"); then
    hard_error "$path: $json."
    return 0
  fi
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
    [ (.ignoredvulns // [])[]
      | {what: "IgnoredVulns \(.id // "<no id>")", reason: (.reason // ""), until: (.ignoreuntil | day)} ]
    + [ (.packageoverrides // [])[]
      | select(.ignore == true or .vulnerability.ignore == true or .license.ignore == true)
      | {what: "PackageOverrides \(.name // "<no name>")", reason: (.reason // ""), until: (.effectiveuntil | day)} ]
    | .[]' <<<"$json")
}

# Directories never scanned for osv-scanner.toml: installed dependencies, not
# the repository's own configuration (they are never committed anyway). A
# `build/` or `vendor/` folder of the repository is checked.
readonly SKIPPED_DIR_RE='(^|/)(\.git|node_modules|\.dart_tool)/'

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
      .gitleaks.toml) check_gitleaks_toml "$base_dir/$path" "$head_dir/$path" ;;
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
      .github/actionlint.y*ml | .github/dependabot.y*ml | .yamllint* | .markdownlint*) ;;
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
        || echo "**Gate change**: $gate_changes change(s) to the Quality Gate, justified in the PR body. The double agent review (code and security) recorded on the PR is the approval; the explicit go of an organisation owner is required to merge." >>"$GITHUB_STEP_SUMMARY"
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
