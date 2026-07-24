#!/usr/bin/env bash
# Validate and archive post-switch production confirmation evidence.
# This script never sends model requests, uses Test Connection, evaluates input,
# or changes production services.
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly SKILL_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
readonly DEFAULT_RUN_ROOT="/root/backups/sub2api/upgrade-runs"
readonly DEFAULT_SOURCE_REPO="/root/sub2api-repo"
readonly DEFAULT_PROD_DEPLOY="/root/sub2api-prod-deploy"
readonly DEFAULT_DEBUG_DEPLOY="/root/sub2api-debug-deploy"
readonly OWNER_MARK="sub2api-upgrade-v1"
readonly APP_IMAGE_REPOSITORY="ghcr.io/wesperez/sub2api"
readonly APP_HEALTH_URL="http://127.0.0.1:13080/health"
readonly ROUTER_UPSTREAM_CONFIG="/etc/nginx/conf.d/codex-unified-router-upstream.conf"
readonly PUBLIC_HOST="wooai.cc.cd"
readonly DEFAULT_DEBUG_LOCK="/run/lock/sub2api-debug-adapter.lock"
# Keep in lockstep with run-debug-matrix.sh and debug-canary-adapters/log-gate.sh.
readonly FATAL_LOG_PATTERN='panic|fatal|migration[^[:alnum:]]*(failed|failure|error)|checksum[^[:alnum:]]*(mismatch|failed|failure|error)|out of memory|oom[-_ ]?killed|response\.failed'
readonly EC_FAILED=2
readonly EC_BLOCKED=3

RUN_ROOT="$DEFAULT_RUN_ROOT"
SOURCE_REPO="$DEFAULT_SOURCE_REPO"
PROD_DEPLOY="$DEFAULT_PROD_DEPLOY"
DEBUG_DEPLOY="$DEFAULT_DEBUG_DEPLOY"
DOCKER_BIN="/usr/bin/docker"
CURL_BIN="/usr/bin/curl"
GIT_BIN="/usr/bin/git"
RUN_ID=""
STOP_DEBUG=0
JSON_OUT=0
TEST_MODE=0
REQUIRE_PROVIDERS=""
declare -a CANARY_EVIDENCE=()
declare -a REQUIRED=()
declare -a CONFIRMED=()
declare -a CANARY_BINDINGS=()

usage() {
  cat <<'USAGE'
Usage:
  confirm-production-upgrade.sh --run-id <upgrade-id> \
    --canary-evidence <file.json> [--canary-evidence <file.json> ...] \
    [--require-providers a,b] [--stop-debug] [--json]
USAGE
}
info() { printf '%s\n' "[sub2api-post-confirm] $*" >&2; }
die() { local code="$1"; shift; printf '%s\n' "[sub2api-post-confirm] error: $*" >&2; exit "$code"; }
fail() { die "$EC_FAILED" "$*"; }
block() { die "$EC_BLOCKED" "$*"; }
usage_fail() { die 1 "$*"; }
sha() { sha256sum -- "$1" | awk '{print $1}'; }
under_tmp() { [[ "$(realpath -m "$1")" == /tmp/* ]]; }
manifest_value() { awk -F= -v key="$1" '$1==key {v=substr($0,length(key)+2)} END{print v}' "$2"; }
last_manifest_value() { manifest_value "$@"; }
hex40() { [[ "$1" =~ ^[0-9a-f]{40}$ ]]; }
digest() { [[ "$1" =~ ^sha256:[0-9a-f]{64}$ ]]; }
rfc3339z() { [[ "$1" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; }
run_id_ok() { [[ "$1" =~ ^upgrade-[0-9]{8}T[0-9]{6}Z-[0-9a-f]{12}$ ]]; }

parse_args() {
  while (( $# )); do
    case "$1" in
      --run-id) (( $# >= 2 )) || usage_fail "--run-id requires a value"; RUN_ID="$2"; shift ;;
      --canary-evidence) (( $# >= 2 )) || usage_fail "--canary-evidence requires a value"; CANARY_EVIDENCE+=("$2"); shift ;;
      --require-providers) (( $# >= 2 )) || usage_fail "--require-providers requires a value"; REQUIRE_PROVIDERS="$2"; shift ;;
      --stop-debug) STOP_DEBUG=1 ;;
      --json) JSON_OUT=1 ;;
      --help|-h) usage; exit 0 ;;
      --command|--cmd|--url|--path|--target|--script|--exec|--eval|--apply) usage_fail "refusing argument: $1" ;;
      *) usage_fail "unknown argument: $1" ;;
    esac
    shift
  done
  [[ -n "$RUN_ID" ]] || usage_fail "--run-id is required"
  run_id_ok "$RUN_ID" || usage_fail "invalid run id"
  (( ${#CANARY_EVIDENCE[@]} > 0 )) || usage_fail "at least one --canary-evidence is required"
}

configure_test_mode() {
  [[ "${SUB2API_UPGRADE_TEST_MODE:-}" == "1" ]] || return 0
  TEST_MODE=1
  [[ -n "${SUB2API_POST_CONFIRM_TEST_RUN_ROOT:-}" ]] || usage_fail "test mode requires SUB2API_POST_CONFIRM_TEST_RUN_ROOT"
  under_tmp "$SUB2API_POST_CONFIRM_TEST_RUN_ROOT" || usage_fail "test run root must be under /tmp"
  RUN_ROOT="$(realpath -m "$SUB2API_POST_CONFIRM_TEST_RUN_ROOT")"
  local item value
  for item in SOURCE_REPO PROD_DEPLOY DEBUG_DEPLOY DOCKER CURL GIT PREFLIGHT DEBUG_LOCK; do
    value="SUB2API_POST_CONFIRM_TEST_$item"
    [[ -n "${!value:-}" ]] || continue
    under_tmp "${!value}" || usage_fail "test override $value must be under /tmp"
    case "$item" in
      SOURCE_REPO) SOURCE_REPO="$(realpath -m "${!value}")" ;;
      PROD_DEPLOY) PROD_DEPLOY="$(realpath -m "${!value}")" ;;
      DEBUG_DEPLOY) DEBUG_DEPLOY="$(realpath -m "${!value}")" ;;
      DOCKER) DOCKER_BIN="$(realpath -m "${!value}")" ;;
      CURL) CURL_BIN="$(realpath -m "${!value}")" ;;
      GIT) GIT_BIN="$(realpath -m "${!value}")" ;;
    esac
  done
}

run_dir_for() {
  local path="$RUN_ROOT/$RUN_ID"
  [[ -d "$path" ]] || block "run directory is missing: $path"
  if (( TEST_MODE )); then under_tmp "$path" || block "test run must be under /tmp"
  else [[ "$(realpath -e "$path")" == "$(realpath -e "$RUN_ROOT")/"* ]] || block "run directory escapes root"; fi
  [[ "$(tr -d '[:space:]' <"$path/.owner" 2>/dev/null || true)" == "$OWNER_MARK" ]] || block "run is not owned by this skill"
  printf '%s\n' "$(realpath -e "$path")"
}

repo_digests_match() {
  jq -e --arg repo "$APP_IMAGE_REPOSITORY" --arg digest "$2" 'type=="array" and ([.[]|select(.==($repo+"@"+$digest))]|length)==1' >/dev/null <<<"$1"
}

assert_identity() {
  local expected_revision="$1" expected_digest="$2" expected_image="$3"
  local -a containers=()
  mapfile -t containers < <("$DOCKER_BIN" ps -q --filter 'name=^/sub2api-prod$')
  [[ "${#containers[@]}" == 1 ]] || fail "production application container is not uniquely running"
  local image rev ref digests
  image="$("$DOCKER_BIN" inspect -f '{{.Image}}' "${containers[0]}")"
  rev="$("$DOCKER_BIN" image inspect -f '{{index .Config.Labels "org.opencontainers.image.revision"}}' "$image")"
  ref="$("$DOCKER_BIN" image inspect -f '{{index .Config.Labels "org.opencontainers.image.ref.name"}}' "$image")"
  digests="$("$DOCKER_BIN" image inspect -f '{{json .RepoDigests}}' "$image")"
  [[ "$image" == "$expected_image" ]] || fail "running production image id drifted from bound run"
  [[ "$rev" == "$expected_revision" ]] || fail "running production revision drifted from bound run"
  repo_digests_match "$digests" "$expected_digest" || fail "running production digest drifted from bound run"
  [[ "$ref" == debug || "$ref" == mine ]] || fail "running image has unsupported ref.name"
}

check_heads() {
  local expected="$1" refs mine debug
  refs="$("$GIT_BIN" -C "$SOURCE_REPO" ls-remote --exit-code origin refs/heads/mine refs/heads/debug)" || fail "could not read origin/mine and origin/debug"
  mine="$(awk '$2=="refs/heads/mine"{print $1}' <<<"$refs")"
  debug="$(awk '$2=="refs/heads/debug"{print $1}' <<<"$refs")"
  [[ "$mine" == "$expected" && "$debug" == "$expected" ]] || fail "origin/mine or origin/debug drifted from candidate"
}

check_http() {
  local url="$1" expected="$2" body
  body="$("$CURL_BIN" --noproxy '*' --fail --silent --show-error --max-time 10 "$url")" || return 1
  jq -e --arg expected "$expected" 'type=="object" and .status==$expected' >/dev/null <<<"$body"
}

check_baseline_or_preflight() {
  if (( TEST_MODE )) && [[ -n "${SUB2API_POST_CONFIRM_TEST_PREFLIGHT:-}" ]]; then
    bash "$SUB2API_POST_CONFIRM_TEST_PREFLIGHT" || fail "test preflight failed"
  elif (( ! TEST_MODE )); then
    [[ -x "$SCRIPT_DIR/update-sub2api.sh" ]] || block "update-sub2api.sh is unavailable"
    bash "$SCRIPT_DIR/update-sub2api.sh" --preflight >/dev/null || fail "production preflight failed"
    return
  fi
  check_http "$APP_HEALTH_URL" ok || fail "application health endpoint is not healthy"
  check_http "http://127.0.0.1:13083/ready" ready || fail "Router ready endpoint is not ready"
  local public
  public="$("$CURL_BIN" --noproxy '*' --ipv4 --fail --silent --show-error --max-time 10 --resolve "$PUBLIC_HOST:443:127.0.0.1" "https://$PUBLIC_HOST/ready")" || true
  jq -e 'type=="object" and .status=="ready"' >/dev/null <<<"$public" || fail "Nginx/SNI public ready endpoint is not ready"
}

verify_dump() {
  local run_dir="$1" manifest="$run_dir/manifest.env" dump dump_sha
  dump="$(manifest_value database_dump "$manifest")"
  dump_sha="$(manifest_value database_dump_sha256 "$manifest")"
  [[ "$dump" == "$run_dir/postgres.dump" && -s "$dump" ]] || block "bound run database dump is missing"
  [[ "$dump_sha" =~ ^[0-9a-f]{64}$ && "$(sha "$dump")" == "$dump_sha" ]] || block "bound run database dump sha256 differs"
}

load_required_providers() {
  local plan="$1" inventory inventory_json required_json
  [[ -f "$plan" && ! -L "$plan" ]] || block "verification-plan.json is missing"
  inventory="$(jq -c '.selection.active_inventory // null' "$plan")"
  jq -e '
    type=="object" and .present==true
    and (.providers|type=="array" and length>0)
    and all(.providers[]; type=="string" and test("^[a-z][a-z0-9_-]{0,31}$"))
    and ((.providers|unique|length)==(.providers|length))
  ' >/dev/null <<<"$inventory" || block "verification plan has no valid active_inventory.providers"
  mapfile -t REQUIRED < <(jq -r '.providers[]' <<<"$inventory" | LC_ALL=C sort -u)
  if [[ -n "$REQUIRE_PROVIDERS" ]]; then
    local -a narrowed=() cleaned=()
    local provider
    IFS=',' read -r -a narrowed <<<"$REQUIRE_PROVIDERS"
    (( ${#narrowed[@]} > 0 )) || usage_fail "--require-providers is empty"
    for provider in "${narrowed[@]}"; do
      provider="$(tr -d '[:space:]' <<<"$provider")"
      [[ "$provider" =~ ^[a-z][a-z0-9_-]{0,31}$ ]] || usage_fail "invalid required provider"
      cleaned+=("$provider")
    done
    inventory_json="$(printf '%s\n' "${REQUIRED[@]}" | jq -R . | jq -s 'sort')"
    required_json="$(printf '%s\n' "${cleaned[@]}" | jq -R . | jq -s 'sort|unique')"
    [[ "$required_json" == "$inventory_json" ]] \
      || block "--require-providers must exactly match active inventory providers"
  fi
}

is_placeholder() {
  local value
  value="$(tr '[:upper:]' '[:lower:]' <<<"$1")"
  [[ "$value" == *placeholder* || "$value" == *todo* || "$value" == *tbd* || "$value" == *replace-me* || "$value" == *operator-or-agent-id* || "$value" == *describe\ the\ exact* || "$value" =~ ^(xxx|yyy|zzz|changeme|n/?a|none|null|unknown)$ ]]
}

validate_evidence() {
  local evidence="$1" revision="$2" expected_digest="$3" passed_at="$4" now="$5"
  local provider verifier procedure observed_at passed_epoch observed_epoch now_epoch
  [[ -f "$evidence" && ! -L "$evidence" ]] || block "canary evidence is missing or symlinked: $evidence"
  (( ! TEST_MODE )) || under_tmp "$evidence" || block "test canary evidence must be under /tmp"
  jq -e --arg revision "$revision" --arg digest "$expected_digest" --arg run "$RUN_ID" '
    type=="object"
    and ((keys | sort)==["assertions","client","digest","kind","procedure","provider","request","result","revision","run_id","schema_version","verifier"])
    and .schema_version==1 and .kind=="production-live-confirmation"
    and .revision==$revision and .digest==$digest and .run_id==$run
    and (.provider|type=="string" and test("^[a-z][a-z0-9_-]{0,31}$"))
    and (.client|type=="object" and ((keys | sort)==["note","type","version"] or (keys | sort)==["type","version"] or (keys | sort)==["type"]) and .type=="official-codex")
    and ((.client.version // "")|type=="string" and length<=64)
    and ((.client.note // "")|type=="string" and length<=200)
    and (.request|type=="object" and ((keys | sort)==["model","task_class"] or (keys | sort)==["model","request_id","task_class"] or (keys | sort)==["model","task_class","thread_id"] or (keys | sort)==["model","request_id","task_class","thread_id"]))
    and (.request.model|type=="string" and length>0 and length<=128 and test("^[A-Za-z0-9._:-]+$"))
    and (.request.task_class=="structured-smoke" or .request.task_class=="semantic-smoke" or .request.task_class=="protocol-smoke")
    and ((.request.request_id // "")|type=="string" and length<=128)
    and ((.request.thread_id // "")|type=="string" and length<=128)
    and (.result|type=="object" and ((keys | sort)==["http_or_transport_ok","observed_at","passed","semantic_ok"]) and .passed==true and .http_or_transport_ok==true and .semantic_ok==true)
    and (.result.observed_at|type=="string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
    and (.assertions|type=="array" and length>0 and all(.[]; type=="object" and ((keys | sort)==["name","passed"]) and (.name|type=="string" and length>0 and length<=128 and test("^[A-Za-z0-9._:-]+$")) and .passed==true))
    and (.verifier|type=="string" and length>=3 and length<=128)
    and (.procedure|type=="string" and length>=20 and length<=2000)
  ' "$evidence" >/dev/null || fail "canary evidence failed strict schema/semantic validation: $evidence"
  provider="$(jq -r .provider "$evidence")"
  verifier="$(jq -r .verifier "$evidence")"
  procedure="$(jq -r .procedure "$evidence")"
  is_placeholder "$verifier" && fail "canary verifier is a placeholder"
  is_placeholder "$procedure" && fail "canary procedure is a placeholder"
  local procedure_text compact_text token_text
  procedure_text="$(jq -r '(.client.note // "") + " " + .procedure | ascii_downcase' "$evidence")"
  compact_text="$(tr -cd '[:alnum:]' <<<"$procedure_text")"
  token_text=" $(tr -cs '[:alnum:]' ' ' <<<"$procedure_text") "
  [[ "$compact_text" == *testconnection* || "$compact_text" == *rawcurl* || "$compact_text" == *forgedcodex* \
    || "$token_text" == *' eval '* ]] && fail "canary evidence claims a forbidden procedure"
  observed_at="$(jq -r .result.observed_at "$evidence")"
  passed_epoch="$(date -u -d "$passed_at" +%s 2>/dev/null || true)"
  observed_epoch="$(date -u -d "$observed_at" +%s 2>/dev/null || true)"
  now_epoch="$(date -u -d "$now" +%s 2>/dev/null || true)"
  [[ "$passed_epoch" =~ ^[0-9]+$ && "$observed_epoch" =~ ^[0-9]+$ && "$now_epoch" =~ ^[0-9]+$ ]] \
    || fail "canary evidence has an invalid observation time"
  (( observed_epoch >= passed_epoch && observed_epoch <= now_epoch )) \
    || fail "canary evidence was not observed inside the post-switch confirmation window"
  printf '%s\n' "$provider"
}

next_attempt() {
  local root="$1" n=1 path
  while :; do
    path="$root/attempt-$(printf '%03d' "$n")"
    [[ ! -e "$path" ]] && { printf '%s\n' "$path"; return; }
    n=$((n+1))
    (( n <= 999 )) || block "too many post-confirm attempts"
  done
}

collect_logs() {
  local attempt="$1" since="$2" until="$3"
  local compose="$PROD_DEPLOY/docker-compose.yml" out="$attempt/log-window.raw" argv="$attempt/log-collect.argv" stderr="$attempt/log-collect.stderr"
  [[ -f "$compose" ]] || block "production compose file missing"
  if (( TEST_MODE )); then under_tmp "$compose" || block "test production compose must be under /tmp"
  else [[ "$(realpath -e "$compose")" == "/root/sub2api-prod-deploy/docker-compose.yml" ]] || block "production compose path drifted"; fi
  local -a cmd=("$DOCKER_BIN" compose --project-directory "$PROD_DEPLOY" -f "$compose" logs --no-color --timestamps --since "$since" --until "$until" sub2api)
  : > "$argv"
  local arg; for arg in "${cmd[@]}"; do printf '%s\n' "$arg" >> "$argv"; done
  chmod 0600 "$argv"
  "${cmd[@]}" >"$out" 2>"$stderr" || { rm -f -- "$out"; block "production log collection failed"; }
  chmod 0600 "$out" "$stderr"
  local log_sha hits=0 log_empty=false byte_count line_count
  log_sha="$(sha "$out")"
  [[ -s "$out" ]] || log_empty=true
  byte_count="$(stat -c '%s' "$out")"
  line_count="$(awk 'END {print NR+0}' "$out")"
  if grep -Eiq -- "$FATAL_LOG_PATTERN" "$out"; then
    hits="$(grep -Eic -- "$FATAL_LOG_PATTERN" "$out" || true)"
    fail "production log window contains fatal patterns (count=$hits)"
  fi
  jq -n --arg since "$since" --arg until "$until" --arg sha "$log_sha" --arg compose "$compose" \
    --argjson empty "$log_empty" --argjson bytes "$byte_count" --argjson lines "$line_count" \
    '{collected:true,scope:"sub2api",project:"sub2api-prod",since:$since,until:$until,path:"log-window.raw",sha256:$sha,compose_file:$compose,raw_printed:false,fatal_hits:0,empty:$empty,byte_count:$bytes,line_count:$lines}' \
    > "$attempt/log-window.meta.json"
  chmod 0600 "$attempt/log-window.meta.json"
  printf '%s\n' "$log_sha"
}

stop_debug() {
  (( STOP_DEBUG )) || return 0
  local lock="$DEFAULT_DEBUG_LOCK"
  if (( TEST_MODE )) && [[ -n "${SUB2API_POST_CONFIRM_TEST_DEBUG_LOCK:-}" ]]; then lock="$SUB2API_POST_CONFIRM_TEST_DEBUG_LOCK"; fi
  install -d -m 0755 "$(dirname -- "$lock")" 2>/dev/null || true
  exec 8>"$lock" || block "cannot open debug adapter lock"
  flock -n 8 || block "could not acquire exclusive debug adapter lock"
  local compose="$DEBUG_DEPLOY/docker-compose.yml"
  [[ -f "$compose" ]] || block "debug compose file missing"
  if (( TEST_MODE )); then under_tmp "$compose" || block "test debug compose must be under /tmp"
  else [[ "$(realpath -e "$DEBUG_DEPLOY")" == "/root/sub2api-debug-deploy" ]] || block "debug deploy path drifted"; fi
  "$DOCKER_BIN" compose --project-directory "$DEBUG_DEPLOY" -f "$compose" stop >/dev/null || block "debug compose stop failed"
}

write_confirmation() {
  local attempt="$1" number="$2" revision="$3" expected_digest="$4" log_sha="$5" since="$6" until="$7" stopped="$8"
  local required_json confirmed_json canaries_json log_window_json now
  required_json="$(printf '%s\n' "${REQUIRED[@]}" | jq -R . | jq -s 'sort')"
  confirmed_json="$(printf '%s\n' "${CONFIRMED[@]}" | jq -R . | jq -s 'sort')"
  canaries_json="$(printf '%s\n' "${CANARY_BINDINGS[@]}" | jq -R '
    split("\t") | {provider:.[0],path:.[1],sha256:.[2]}
  ' | jq -s 'sort_by(.provider)')"
  log_window_json="$(jq -c . "$attempt/log-window.meta.json")"
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  jq -n --arg run "$RUN_ID" --arg revision "$revision" --arg digest "$expected_digest" --arg now "$now" --argjson stopped "$stopped" --argjson attempt "$number" --argjson required "$required_json" --argjson confirmed "$confirmed_json" --argjson canaries "$canaries_json" --argjson log_window "$log_window_json" '
      {schema_version:1,kind:"production-post-confirmation",status:"passed",run_id:$run,revision:$revision,digest:$digest,
       attempt:$attempt,confirmed_at:$now,providers_required:$required,providers_confirmed:$confirmed,
       canaries:$canaries,
       log_window:$log_window,
       checks:{exact_revision_digest:true,origin_heads_match:true,preflight_or_health:true},
       stop_debug:$stopped,raw_model_request_executed:false,test_connection_used:false}' > "$attempt/confirmation.json"
  chmod 0600 "$attempt/confirmation.json"
}

main() {
  parse_args "$@"
  configure_test_mode
  local command
  for command in jq sha256sum awk realpath flock grep date stat; do command -v "$command" >/dev/null 2>&1 || usage_fail "required command unavailable: $command"; done
  local run_dir manifest status revision expected_digest image passed_at
  run_dir="$(run_dir_for)"
  manifest="$run_dir/manifest.env"
  [[ -f "$manifest" && ! -L "$manifest" ]] || block "run manifest is missing"
  status="$(last_manifest_value status "$manifest")"
  [[ "$status" == passed_pending_finalization || "$status" == finalized ]] || block "run status is not confirmable: ${status:-missing}"
  revision="$(manifest_value candidate_revision "$manifest")"
  expected_digest="$(manifest_value expected_digest "$manifest")"
  image="$(manifest_value candidate_image_id "$manifest")"
  passed_at="$(manifest_value passed_at "$manifest")"
  hex40 "$revision" || block "candidate revision is invalid"
  digest "$expected_digest" || block "expected digest is invalid"
  [[ "$image" =~ ^sha256:[0-9a-f]{64}$ ]] || block "candidate image id is invalid"
  rfc3339z "$passed_at" || block "passed_at is missing or invalid"
  verify_dump "$run_dir"
  load_required_providers "$run_dir/verification-plan.json"

  # Identity and fixed production preflight happen before evidence ingest/log archive.
  assert_identity "$revision" "$expected_digest" "$image"
  check_heads "$revision"
  check_baseline_or_preflight

  local now passed_epoch now_epoch
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  passed_epoch="$(date -u -d "$passed_at" +%s 2>/dev/null || true)"
  now_epoch="$(date -u +%s)"
  [[ "$passed_epoch" =~ ^[0-9]+$ && "$now_epoch" -ge "$passed_epoch" ]] || block "passed_at cannot define a valid log window"
  install -d -m 0700 "$run_dir/post-confirm"
  exec 9>"$run_dir/post-confirm/.lock" || block "cannot open post-confirm lock"
  flock -n 9 || block "another post-confirm attempt is active for this run"
  local attempt attempt_name number log_sha
  attempt="$(next_attempt "$run_dir/post-confirm")"
  install -d -m 0700 "$attempt" "$attempt/canary"
  attempt_name="$(basename "$attempt")"
  number=$((10#${attempt_name#attempt-}))
  log_sha="$(collect_logs "$attempt" "$passed_at" "$now")"

  declare -A seen=()
  local evidence provider required allowed dest canary_sha
  for evidence in "${CANARY_EVIDENCE[@]}"; do
    provider="$(validate_evidence "$evidence" "$revision" "$expected_digest" "$passed_at" "$now")"
    [[ -z "${seen[$provider]+x}" ]] || fail "duplicate canary evidence provider: $provider"
    allowed=0
    for required in "${REQUIRED[@]}"; do [[ "$required" == "$provider" ]] && allowed=1; done
    (( allowed )) || fail "canary evidence provider is not required: $provider"
    dest="$attempt/canary/$provider.json"
    install -m 0600 "$evidence" "$dest"
    canary_sha="$(sha "$dest")"
    printf '%s\n' "$canary_sha" > "$attempt/canary/$provider.sha256"
    chmod 0600 "$attempt/canary/$provider.sha256"
    seen["$provider"]=1
    CONFIRMED+=("$provider")
    CANARY_BINDINGS+=("$provider"$'\t'"canary/$provider.json"$'\t'"$canary_sha")
  done
  for required in "${REQUIRED[@]}"; do [[ -n "${seen[$required]+x}" ]] || fail "missing required canary evidence: $required"; done

  local stopped=false
  if (( STOP_DEBUG )); then stop_debug; stopped=true; fi
  write_confirmation "$attempt" "$number" "$revision" "$expected_digest" "$log_sha" "$passed_at" "$now" "$stopped"
  install -m 0600 "$attempt/confirmation.json" "$run_dir/post-confirm/confirmation.json"
  local confirmation_sha
  confirmation_sha="$(sha "$run_dir/post-confirm/confirmation.json")"
  printf 'post_confirm_status=passed\npost_confirm_at=%s\npost_confirm_attempt=%s\npost_confirm_sha256=%s\npost_confirm_log_window_sha256=%s\npost_confirm_dir=%s\npost_confirm_file=%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$number" "$confirmation_sha" "$log_sha" "$attempt" \
    "$run_dir/post-confirm/confirmation.json" >> "$manifest"
  if (( JSON_OUT )); then cat "$run_dir/post-confirm/confirmation.json"
  else printf 'status=passed\nrun_id=%s\nattempt=%03d\nconfirmation=%s\n' "$RUN_ID" "$number" "$run_dir/post-confirm/confirmation.json"; fi
}

main "$@"
