#!/usr/bin/env bash
# Gate integrity: detects a pull request that weakens the Quality Gate
# (SchoolEngine/.github#22). Copied as is into every SchoolEngine repository;
# the `gate-integrity` job of ci.yml runs the copy of the BASE branch, so a
# pull request is never judged by its own version of this script.
#
# Usage:
#   gate-integrity.sh ci <base-ref>            what the CI job runs (repository root)
#   gate-integrity.sh workflow <base.yml> <head.yml>
#   gate-integrity.sh ignores <base-dir> <head-dir>
#
# Environment: PR_TITLE and PR_BODY (the `## Gate change` exception),
# GATE_INTEGRITY_TODAY (YYYY-MM-DD, tests only). Requires yq (YAML), python3
# (tomllib, TOML), jq, git and, for `ci`, actionlint.
#
# Two kinds of findings:
# - hard: never accepted (a mandatory job missing, the gate's `if:` or
#   `needs:` weakened, `continue-on-error`, an ignore without justification
#   or expiry date);
# - gate change: accepted only when the PR title type is `ci` AND the body
#   has a `## Gate change` section with a justification (a job of the base
#   branch removed, the definition of a common job or of the gate changed, a
#   loosened gitleaks configuration). Such a PR gets the double agent review
#   and Céline's explicit approval (CI.md).
set -euo pipefail

readonly COMMON_JOBS=(pr-conventions gitleaks actionlint lint-yaml-markdown osv-scanner gate-integrity)
readonly GATE_JOB="quality-gate"
readonly GATE_NAME="Quality Gate"
# shellcheck disable=SC2016  # a literal GitHub expression, not a shell one
readonly GATE_IF='${{ !cancelled() }}'
readonly DATE_RE='[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])'

hard=0
gate_changes=0
today="${GATE_INTEGRITY_TODAY:-$(date -u +%F)}"

hard_error() {
  echo "::error::$1"
  hard=$((hard + 1))
}

gate_change() {
  echo "::warning::Gate change: $1"
  gate_changes=$((gate_changes + 1))
}

yaml_json() { yq -o json '.' "$1"; }

toml_json() {
  python3 -I -c 'import json, sys, tomllib
with open(sys.argv[1], "rb") as f:
    print(json.dumps(tomllib.load(f), default=str))' "$1"
}

# Accepted only for a `ci` title and a non-empty `## Gate change` section.
gate_change_justified() {
  local title_re='^ci(\([a-z0-9._/-]+\))?!?: '
  [[ "${PR_TITLE:-}" =~ $title_re ]] || return 1
  printf '%s\n' "${PR_BODY:-}" | tr -d '\r' | awk '
    /^##[[:space:]]+Gate change[[:space:]]*$/ { in_section = 1; next }
    in_section && /^#{1,2}[[:space:]]/ { in_section = 0 }
    in_section && /[[:alnum:]]/ && !/^[[:space:]]*<!--/ { found = 1 }
    END { exit found ? 0 : 1 }'
}

# --- The workflow -----------------------------------------------------------

# A job definition without the action SHAs (Dependabot bumps them), as JSON.
normalized_job() {
  jq -S --arg job "$2" '.jobs[$job]
    | walk(if type == "object" and (.uses | type) == "string"
           then .uses |= sub("@[0-9a-f]{40}$"; "@<sha>") else . end)
    | if $job == "quality-gate" then del(.needs) else . end' <<<"$1"
}

check_workflow() {
  local base_file=$1 head_file=$2 head base="" job
  head=$(yaml_json "$head_file")
  if [[ -s "$base_file" ]]; then
    base=$(yaml_json "$base_file")
  else
    echo "::notice::No ci.yml on the base branch: base comparison skipped."
  fi

  for job in "${COMMON_JOBS[@]}" "$GATE_JOB"; do
    jq -e --arg job "$job" '.jobs | has($job)' <<<"$head" >/dev/null \
      || hard_error "Mandatory job '$job' is missing from ci.yml."
  done
  jq -e --arg job "$GATE_JOB" '.jobs | has($job)' <<<"$head" >/dev/null || return 0

  [[ "$(jq -r --arg job "$GATE_JOB" '.jobs[$job].name // ""' <<<"$head")" == "$GATE_NAME" ]] \
    || hard_error "Job '$GATE_JOB' must be named exactly '$GATE_NAME' (the required check)."
  [[ "$(jq -r --arg job "$GATE_JOB" '.jobs[$job].if // ""' <<<"$head")" == "$GATE_IF" ]] \
    || hard_error "The 'if:' of '$GATE_JOB' must be exactly $GATE_IF (a skipped required check passes)."

  local missing
  missing=$(jq -r --arg job "$GATE_JOB" '
    (.jobs[$job].needs // [] | if type == "string" then [.] else . end) as $needs
    | .jobs | keys[] | select(. != $job and (. as $j | $needs | index($j) | not))' <<<"$head")
  for job in $missing; do
    hard_error "Job '$job' is not in the 'needs:' of '$GATE_JOB': it would block nothing."
  done

  local coe
  coe=$(jq -r '[.jobs | paths | select(.[-1] == "continue-on-error") | map(tostring) | join(".")] | join(", ")' <<<"$head")
  [[ -z "$coe" ]] || hard_error "continue-on-error is forbidden (a failing job would pass the gate): $coe."

  [[ -n "$base" ]] || return 0

  for job in $(jq -r --arg gate "$GATE_JOB" '.jobs | keys[] | select(. != $gate)' <<<"$base"); do
    jq -e --arg job "$job" '.jobs | has($job)' <<<"$head" >/dev/null \
      || gate_change "job '$job' of the base branch was removed."
  done

  for job in "${COMMON_JOBS[@]}" "$GATE_JOB"; do
    jq -e --arg job "$job" '(.jobs | has($job))' <<<"$base" >/dev/null || continue
    jq -e --arg job "$job" '(.jobs | has($job))' <<<"$head" >/dev/null || continue
    if ! diff -u --label "base: $job" --label "pr: $job" \
        <(normalized_job "$base" "$job") <(normalized_job "$head" "$job"); then
      gate_change "the definition of job '$job' changed (diff above)."
    fi
  done
}

# --- The ignore files (ADR-014) ---------------------------------------------

# "<justification> expires: YYYY-MM-DD", the date not in the past.
check_expiring_text() {
  local where=$1 text=$2 date
  if [[ ! "$text" =~ [[:alnum:]].*expires:[[:space:]]*($DATE_RE)[[:space:]]*$ ]]; then
    hard_error "$where: needs a justification ending with 'expires: YYYY-MM-DD'."
    return 0
  fi
  date=${BASH_REMATCH[1]}
  [[ ! "$date" < "$today" ]] || hard_error "$where: expired on $date: remove the ignore or renew it with a new justification."
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
  while IFS= read -r description; do
    check_expiring_text ".gitleaks.toml allowlist '${description:-<no description>}'" "$description"
  done < <(jq -r '
    ([.allowlist // empty] + (.allowlists // [])
     + [.rules[]? | (.allowlist // empty), (.allowlists // [])[]])
    | .[] | .description // ""' <<<"$json")
}

check_osv_toml() {
  local file=$1 json bad
  json=$(toml_json "$file")
  bad=$(jq -r '
    [ (.IgnoredVulns // [])[]
      | select(((.reason // "") | test("[[:alnum:]]") | not) or (.ignoreUntil == null))
      | "IgnoredVulns \(.id // "<no id>")" ]
    + [ (.PackageOverrides // [])[]
      | select(.ignore == true or .vulnerability.ignore == true or .license.ignore == true)
      | select(((.reason // "") | test("[[:alnum:]]") | not) or (.effectiveUntil == null))
      | "PackageOverrides \(.name // "<no name>")" ]
    | .[]' <<<"$json")
  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    hard_error "$file: $entry needs a 'reason' and an expiry ('ignoreUntil' or 'effectiveUntil')."
  done <<<"$bad"
}

check_ignores() {
  local base_dir=$1 head_dir=$2 path
  local -a paths=()
  while IFS= read -r path; do
    paths+=("$path")
  done < <(cd "$head_dir" && find . -path ./.git -prune -o -path '*/node_modules' -prune -o \
             \( -name osv-scanner.toml -o -path ./.gitleaks.toml -o -path ./.gitleaksignore \) -type f -print \
           | sed 's|^\./||' | sort)

  while IFS= read -r path; do
    [[ -n "$path" && ! -f "$head_dir/$path" ]] || continue
    echo "::notice::$path was removed by this PR."
  done < <(cd "$base_dir" && find . -type f -print 2>/dev/null | sed 's|^\./||' | grep -E '(^|/)osv-scanner\.toml$|^\.gitleaks(\.toml|ignore)$' || true)

  for path in "${paths[@]}"; do
    if [[ -f "$base_dir/$path" ]] && cmp -s "$base_dir/$path" "$head_dir/$path"; then
      :
    else
      echo "Changes to $path:"
      diff -u --label "base: $path" --label "pr: $path" \
        "$( [[ -f "$base_dir/$path" ]] && echo "$base_dir/$path" || echo /dev/null)" "$head_dir/$path" || true
    fi
    case "$path" in
      .gitleaksignore) check_gitleaksignore "$head_dir/$path" ;;
      .gitleaks.toml) check_gitleaks_toml "$head_dir/$path" ;;
      *) check_osv_toml "$head_dir/$path" ;;
    esac
  done
}

# --- CI entry point ---------------------------------------------------------

run_ci() {
  local base_ref=$1 base_dir path
  base_dir=$(mktemp -d)
  BASE_TMP=$base_dir
  trap 'rm -rf "$BASE_TMP"' EXIT
  while IFS= read -r path; do
    mkdir -p "$base_dir/$(dirname "$path")"
    git show "$base_ref:$path" >"$base_dir/$path"
  done < <(git ls-tree -r --name-only "$base_ref" \
             | grep -E '^\.github/workflows/ci\.yml$|(^|/)osv-scanner\.toml$|^\.gitleaks(\.toml|ignore)$' || true)

  echo "== actionlint: workflows of the PR"
  actionlint || hard_error "actionlint reports findings in the workflows of the PR."
  if [[ -f "$base_dir/.github/workflows/ci.yml" ]]; then
    echo "== actionlint: ci.yml of the base branch (informational)"
    actionlint "$base_dir/.github/workflows/ci.yml" \
      || echo "::warning::actionlint reports findings in the base branch ci.yml (not a verdict on this PR)."
  fi

  echo "== ci.yml against the base branch"
  check_workflow "$base_dir/.github/workflows/ci.yml" .github/workflows/ci.yml
  echo "== Ignore files (gitleaks, osv-scanner)"
  check_ignores "$base_dir" .
}

verdict() {
  if [[ "$gate_changes" -gt 0 ]]; then
    if gate_change_justified; then
      echo "::warning::$gate_changes gate change(s) accepted by the '## Gate change' section: this PR needs the double agent review and Céline's explicit approval."
      [[ -z "${GITHUB_STEP_SUMMARY:-}" ]] \
        || echo "**Gate change**: $gate_changes change(s) to the Quality Gate, justified in the PR body. Double agent review and Céline's explicit approval required." >>"$GITHUB_STEP_SUMMARY"
    else
      echo "::error::$gate_changes gate change(s) without justification: use a 'ci' PR title and a '## Gate change' section in the body (CI.md)."
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
  local command=${1:-}
  case "$command" in
    ci) run_ci "${2:?base ref}" ;;
    workflow) check_workflow "${2:?base ci.yml}" "${3:?head ci.yml}" ;;
    ignores) check_ignores "${2:?base dir}" "${3:?head dir}" ;;
    *) echo "usage: gate-integrity.sh ci <base-ref> | workflow <base.yml> <head.yml> | ignores <base-dir> <head-dir>" >&2; exit 2 ;;
  esac
  verdict
}

main "$@"
