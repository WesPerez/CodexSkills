#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

readonly TEST_MODE="${SUB2API_UPGRADE_TEST_MODE:-0}"
if [[ "$TEST_MODE" == "1" ]]; then
  RUN_ROOT="${SUB2API_FINALIZE_RUN_ROOT:?SUB2API_FINALIZE_RUN_ROOT is required in test mode}"
  APP_HEALTH_URL="${SUB2API_FINALIZE_APP_HEALTH_URL:-http://127.0.0.1:13080/health}"
  ROUTER_UPSTREAM_CONFIG="${SUB2API_FINALIZE_ROUTER_CONFIG:?SUB2API_FINALIZE_ROUTER_CONFIG is required in test mode}"
  PUBLIC_HOST="${SUB2API_FINALIZE_PUBLIC_HOST:-test.invalid}"
  [[ "$(realpath -m "$RUN_ROOT")" == /tmp/* ]] || {
    printf '%s\n' "[sub2api-upgrade] error: test run root must stay under /tmp" >&2
    exit 1
  }
  [[ "$(realpath -m "$ROUTER_UPSTREAM_CONFIG")" == /tmp/* ]] || {
    printf '%s\n' "[sub2api-upgrade] error: test Router config must stay under /tmp" >&2
    exit 1
  }
else
  RUN_ROOT="/root/backups/sub2api/upgrade-runs"
  APP_HEALTH_URL="http://127.0.0.1:13080/health"
  ROUTER_UPSTREAM_CONFIG="/etc/nginx/conf.d/codex-unified-router-upstream.conf"
  PUBLIC_HOST="wooai.cc.cd"
fi
readonly RUN_ROOT APP_HEALTH_URL ROUTER_UPSTREAM_CONFIG PUBLIC_HOST
readonly APP_IMAGE_REPOSITORY="ghcr.io/wesperez/sub2api"
readonly DEFAULT_MIN_AGE_MINUTES=1440
readonly DEFAULT_RETIRE_MIN_AGE_HOURS=24
readonly DEFAULT_PRUNE_MIN_AGE_HOURS=168
readonly DEFAULT_KEEP_RUNS=2

ACTION=""
RUN_ID=""
APPLY=0
MIN_AGE_MINUTES="$DEFAULT_MIN_AGE_MINUTES"
PRUNE_MIN_AGE_HOURS="$DEFAULT_PRUNE_MIN_AGE_HOURS"
RETIRE_MIN_AGE_HOURS="$DEFAULT_RETIRE_MIN_AGE_HOURS"
KEEP_RUNS="$DEFAULT_KEEP_RUNS"

usage() {
  cat <<'USAGE'
Usage:
  finalize-sub2api-upgrade.sh --list
  finalize-sub2api-upgrade.sh --run-id <run-id> [--min-age-minutes N] [--apply]
  finalize-sub2api-upgrade.sh --retire-superseded [--min-age-hours N] [--apply]
  finalize-sub2api-upgrade.sh --prune [--keep N] [--min-age-hours N] [--apply]

Without --apply, the script reports what it would do. Finalization preserves
the database dump and configuration snapshot; it only releases the rollback
image tag created by the named, healthy update run.
Retiring superseded runs releases only rollback tags whose owner-marked
successful rollout chain reaches the currently running production revision.
USAGE
}

info() {
  printf '%s\n' "[sub2api-upgrade] $*"
}

die() {
  printf '%s\n' "[sub2api-upgrade] error: $*" >&2
  exit 1
}

manifest_value() {
  local key="$1"
  local manifest="$2"
  awk -F= -v key="$key" '$1 == key {value = substr($0, length(key) + 2)} END {print value}' "$manifest"
}

run_dir_for() {
  local run_id="$1"
  [[ "$run_id" =~ ^upgrade-[0-9]{8}T[0-9]{6}Z-[0-9a-f]{12}$ ]] || die "invalid run id"
  local path="$RUN_ROOT/$run_id"
  [[ -d "$path" ]] || die "run directory is missing: $path"
  [[ "$(realpath -e "$path")" == "$(realpath -e "$RUN_ROOT")/"* ]] || die "run directory escapes run root"
  [[ "$(cat "$path/.owner" 2>/dev/null || true)" == "sub2api-upgrade-v1" ]] || die "run is not owned by this skill"
  printf '%s\n' "$path"
}

check_status_json() {
  local url="$1"
  local expected_status="$2"
  local body
  body="$(curl --noproxy '*' --fail --silent --show-error --max-time 10 "$url")" || return 1
  jq -e --arg expected "$expected_status" 'type == "object" and .status == $expected' >/dev/null <<<"$body"
}

check_public_ready() {
  local body
  body="$(curl --noproxy '*' --ipv4 --fail --silent --show-error --max-time 10 \
    --resolve "$PUBLIC_HOST:443:127.0.0.1" "https://$PUBLIC_HOST/ready")" || return 1
  jq -e 'type == "object" and .status == "ready"' >/dev/null <<<"$body"
}

resolve_router_ready_url() {
  [[ -f "$ROUTER_UPSTREAM_CONFIG" ]] || return 1
  local -a ports=()
  mapfile -t ports < <(
    sed -nE '/^[[:space:]]*server[[:space:]]+127\.0\.0\.1:(13082|13083)([[:space:]][^;]*)?;([[:space:]]*#.*)?$/ {
      /[[:space:]](backup|down)([[:space:]]|;)/d
      s/^[[:space:]]*server[[:space:]]+127\.0\.0\.1:(13082|13083).*/\1/p
    }' "$ROUTER_UPSTREAM_CONFIG"
  )
  [[ "${#ports[@]}" == "1" ]] || return 1
  printf 'http://127.0.0.1:%s/ready\n' "${ports[0]}"
}

check_baseline() {
  command -v docker >/dev/null 2>&1 || die "docker is unavailable"
  command -v curl >/dev/null 2>&1 || die "curl is unavailable"
  command -v jq >/dev/null 2>&1 || die "jq is unavailable"
  local router_ready_url
  router_ready_url="$(resolve_router_ready_url)" || die "could not resolve the active Router slot from Nginx"
  check_status_json "$APP_HEALTH_URL" "ok" || die "application health endpoint is not healthy"
  check_status_json "$router_ready_url" "ready" || die "active Router ready endpoint is not ready"
  check_public_ready || die "Nginx/SNI public ready endpoint is not ready"
}

run_age_minutes() {
  local path="$1"
  local now anchor manifest passed_at created_at
  now="$(date +%s)"
  manifest="$path/manifest.env"
  anchor=""
  if [[ -f "$manifest" ]]; then
    passed_at="$(manifest_value passed_at "$manifest")"
    created_at="$(manifest_value created_at "$manifest")"
    if [[ "$passed_at" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
      anchor="$(date -u -d "$passed_at" +%s 2>/dev/null || true)"
    elif [[ "$created_at" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
      anchor="$(date -u -d "$created_at" +%s 2>/dev/null || true)"
    fi
  fi
  [[ "$anchor" =~ ^[0-9]+$ ]] || anchor="$(stat -c '%Y' "$path")"
  (( now >= anchor )) || die "run timestamp is in the future: $(basename "$path")"
  printf '%s\n' $(( (now - anchor) / 60 ))
}

assert_positive_integer() {
  [[ "$1" =~ ^[0-9]+$ && "$1" -gt 0 ]] || die "expected a positive integer, got: $1"
}

successful_run_status() {
  case "$1" in
    passed_pending_finalization|finalized|superseded) return 0 ;;
    *) return 1 ;;
  esac
}

current_run_status() {
  case "$1" in
    passed_pending_finalization|finalized) return 0 ;;
    *) return 1 ;;
  esac
}

verify_run_dump() {
  local path="$1" manifest database_dump database_dump_sha256
  manifest="$path/manifest.env"
  database_dump="$(manifest_value database_dump "$manifest")"
  database_dump_sha256="$(manifest_value database_dump_sha256 "$manifest")"
  [[ "$database_dump" == "$path/postgres.dump" ]] || die "run manifest has an unexpected database dump path: $(basename "$path")"
  [[ -s "$database_dump" ]] || die "run database dump is missing or empty: $(basename "$path")"
  [[ "$database_dump_sha256" =~ ^[0-9a-f]{64}$ ]] || die "run database dump has no valid sha256: $(basename "$path")"
  [[ "$(sha256sum "$database_dump" | awk '{print $1}')" == "$database_dump_sha256" ]] \
    || die "run database dump sha256 does not match: $(basename "$path")"
}

verify_post_confirmation() {
  local path="$1" manifest="$2" candidate_revision="$3" expected_digest="$4"
  local post_status post_attempt post_sha post_log_sha post_dir post_file expected_dir
  local confirmation attempt_confirmation log_file
  post_status="$(manifest_value post_confirm_status "$manifest")"
  [[ "$post_status" == "passed" ]] || die "run has no passed post-switch production confirmation"
  post_attempt="$(manifest_value post_confirm_attempt "$manifest")"
  [[ "$post_attempt" =~ ^[0-9]+$ && "$post_attempt" -ge 1 && "$post_attempt" -le 999 ]] \
    || die "run post-confirm attempt is invalid"
  post_sha="$(manifest_value post_confirm_sha256 "$manifest")"
  post_log_sha="$(manifest_value post_confirm_log_window_sha256 "$manifest")"
  [[ "$post_sha" =~ ^[0-9a-f]{64}$ ]] || die "run post-confirm summary has no valid sha256"
  [[ "$post_log_sha" =~ ^[0-9a-f]{64}$ ]] || die "run post-confirm log window has no valid sha256"

  expected_dir="$path/post-confirm/attempt-$(printf '%03d' "$post_attempt")"
  post_dir="$(manifest_value post_confirm_dir "$manifest")"
  post_file="$(manifest_value post_confirm_file "$manifest")"
  [[ "$post_dir" == "$expected_dir" && -d "$post_dir" && ! -L "$post_dir" ]] \
    || die "run post-confirm attempt directory is missing or unsafe"
  [[ "$(realpath -e "$post_dir")" == "$(realpath -e "$expected_dir")" ]] \
    || die "run post-confirm attempt directory escapes its run"
  confirmation="$path/post-confirm/confirmation.json"
  attempt_confirmation="$post_dir/confirmation.json"
  [[ "$post_file" == "$confirmation" && -f "$confirmation" && ! -L "$confirmation" ]] \
    || die "run post-confirm summary file is missing or unsafe"
  [[ -f "$attempt_confirmation" && ! -L "$attempt_confirmation" ]] \
    || die "run post-confirm attempt summary is missing or unsafe"
  [[ "$(sha256sum "$confirmation" | awk '{print $1}')" == "$post_sha" ]] \
    || die "run post-confirm summary checksum differs"
  [[ "$(sha256sum "$attempt_confirmation" | awk '{print $1}')" == "$post_sha" ]] \
    || die "run post-confirm attempt summary checksum differs"

  local run_id
  run_id="$(basename "$path")"
  jq -e --arg run "$run_id" --arg revision "$candidate_revision" --arg digest "$expected_digest" \
    --argjson attempt "$post_attempt" --arg log_sha "$post_log_sha" '
    . as $root
    | type=="object"
    and $root.schema_version==1 and $root.kind=="production-post-confirmation" and $root.status=="passed"
    and $root.run_id==$run and $root.revision==$revision and $root.digest==$digest and $root.attempt==$attempt
    and ($root.confirmed_at|type=="string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
    and ($root.providers_required|type=="array" and length>0)
    and ($root.providers_required==($root.providers_required|sort|unique))
    and ($root.providers_confirmed==$root.providers_required)
    and ($root.canaries|type=="array" and length==($root.providers_required|length))
    and (([$root.canaries[].provider]|sort)==$root.providers_required)
    and all($root.canaries[];
      type=="object"
      and (.provider|type=="string" and test("^[a-z][a-z0-9_-]{0,31}$"))
      and .path==("canary/"+.provider+".json")
      and (.sha256|type=="string" and test("^[0-9a-f]{64}$")))
    and ($root.log_window|type=="object" and .collected==true and .scope=="sub2api" and .project=="sub2api-prod"
      and .path=="log-window.raw" and .sha256==$log_sha and .fatal_hits==0 and .raw_printed==false
      and (.empty|type=="boolean") and (.byte_count|type=="number" and .>=0)
      and (.line_count|type=="number" and .>=0))
    and $root.checks.exact_revision_digest==true and $root.checks.origin_heads_match==true and $root.checks.preflight_or_health==true
    and ($root.stop_debug|type=="boolean")
    and $root.raw_model_request_executed==false and $root.test_connection_used==false
  ' "$confirmation" >/dev/null || die "run post-confirm summary no longer matches production"

  log_file="$post_dir/log-window.raw"
  [[ -f "$log_file" && ! -L "$log_file" ]] || die "run post-confirm log window is missing or unsafe"
  [[ "$(sha256sum "$log_file" | awk '{print $1}')" == "$post_log_sha" ]] \
    || die "run post-confirm log window checksum differs"

  local provider relative expected_sha canary observed_at passed_at confirmed_at
  passed_at="$(manifest_value passed_at "$manifest")"
  confirmed_at="$(jq -r .confirmed_at "$confirmation")"
  while IFS=$'\t' read -r provider relative expected_sha; do
    [[ "$relative" == "canary/$provider.json" ]] || die "run post-confirm canary path is unsafe"
    canary="$post_dir/$relative"
    [[ -f "$canary" && ! -L "$canary" ]] || die "run post-confirm canary is missing or unsafe: $provider"
    [[ "$(sha256sum "$canary" | awk '{print $1}')" == "$expected_sha" ]] \
      || die "run post-confirm canary checksum differs: $provider"
    jq -e --arg run "$run_id" --arg revision "$candidate_revision" --arg digest "$expected_digest" --arg provider "$provider" '
      type=="object" and .schema_version==1 and .kind=="production-live-confirmation"
      and .run_id==$run and .revision==$revision and .digest==$digest and .provider==$provider
      and .client.type=="official-codex"
      and .result.passed==true and .result.http_or_transport_ok==true and .result.semantic_ok==true
      and (.assertions|type=="array" and length>0 and all(.[]; .passed==true))
    ' "$canary" >/dev/null || die "run post-confirm canary no longer satisfies its evidence contract: $provider"
    observed_at="$(jq -r .result.observed_at "$canary")"
    [[ "$(date -u -d "$observed_at" +%s 2>/dev/null || true)" =~ ^[0-9]+$ ]] \
      || die "run post-confirm canary has an invalid observation time: $provider"
    (( $(date -u -d "$observed_at" +%s) >= $(date -u -d "$passed_at" +%s) )) \
      || die "run post-confirm canary predates the production switch: $provider"
    (( $(date -u -d "$observed_at" +%s) <= $(date -u -d "$confirmed_at" +%s) )) \
      || die "run post-confirm canary postdates its confirmation summary: $provider"
  done < <(jq -r '.canaries[] | [.provider,.path,.sha256] | @tsv' "$confirmation")
}

CURRENT_RUN_PATH=""
CURRENT_PRODUCTION_REVISION=""
CURRENT_PRODUCTION_IMAGE_ID=""

resolve_current_production_run() {
  local -a running_containers=() matches=()
  mapfile -t running_containers < <(docker ps -q --filter 'name=^/sub2api-prod$')
  [[ "${#running_containers[@]}" == "1" ]] || die "production application container is not uniquely running"
  local running_container="${running_containers[0]}" running_image running_revision running_repo_digests
  running_image="$(docker inspect -f '{{.Image}}' "$running_container")"
  running_revision="$(docker image inspect -f '{{index .Config.Labels "org.opencontainers.image.revision"}}' "$running_image")"
  [[ "$running_image" =~ ^sha256:[0-9a-f]{64}$ ]] || die "production image id is invalid"
  [[ "$running_revision" =~ ^[0-9a-f]{40}$ ]] || die "production revision is invalid"
  running_repo_digests="$(docker image inspect -f '{{json .RepoDigests}}' "$running_image")"

  local path manifest status candidate_revision candidate_image_id expected_digest
  while IFS= read -r path; do
    [[ "$(cat "$path/.owner" 2>/dev/null || true)" == "sub2api-upgrade-v1" ]] || continue
    manifest="$path/manifest.env"
    [[ -f "$manifest" ]] || continue
    status="$(manifest_value status "$manifest")"
    current_run_status "$status" || continue
    candidate_revision="$(manifest_value candidate_revision "$manifest")"
    candidate_image_id="$(manifest_value candidate_image_id "$manifest")"
    [[ "$candidate_revision" == "$running_revision" && "$candidate_image_id" == "$running_image" ]] || continue
    expected_digest="$(manifest_value expected_digest "$manifest")"
    if [[ -n "$expected_digest" ]]; then
      [[ "$expected_digest" =~ ^sha256:[0-9a-f]{64}$ ]] || die "current run expected digest is invalid"
      jq -e --arg repo "$APP_IMAGE_REPOSITORY" --arg digest "$expected_digest" '
        type=="array" and ([.[] | select(.==($repo+"@"+$digest))] | length)==1
      ' >/dev/null <<<"$running_repo_digests" || die "current production digest differs from its owner-marked run"
    fi
    matches+=("$path")
  done < <(find "$RUN_ROOT" -mindepth 1 -maxdepth 1 -type d -name 'upgrade-*' -print | sort)
  [[ "${#matches[@]}" == "1" ]] || die "could not bind production to exactly one successful owner-marked run"
  CURRENT_RUN_PATH="${matches[0]}"
  CURRENT_PRODUCTION_REVISION="$running_revision"
  CURRENT_PRODUCTION_IMAGE_ID="$running_image"
  verify_run_dump "$CURRENT_RUN_PATH"
}

successor_run_for_revision() {
  local revision="$1" path manifest status previous_revision
  local -a matches=()
  while IFS= read -r path; do
    [[ "$(cat "$path/.owner" 2>/dev/null || true)" == "sub2api-upgrade-v1" ]] || continue
    manifest="$path/manifest.env"
    [[ -f "$manifest" ]] || continue
    status="$(manifest_value status "$manifest")"
    successful_run_status "$status" || continue
    previous_revision="$(manifest_value previous_revision "$manifest")"
    [[ "$previous_revision" == "$revision" ]] || continue
    matches+=("$path")
  done < <(find "$RUN_ROOT" -mindepth 1 -maxdepth 1 -type d -name 'upgrade-*' -print | sort)
  [[ "${#matches[@]}" == "1" ]] || return 1
  printf '%s\n' "${matches[0]}"
}

assert_successor_chain_reaches_production() {
  local path="$1" manifest revision image next_path next_revision next_previous_image next_image hops=0
  manifest="$path/manifest.env"
  revision="$(manifest_value candidate_revision "$manifest")"
  [[ "$revision" =~ ^[0-9a-f]{40}$ ]] || die "superseded run candidate revision is invalid: $(basename "$path")"
  image="$(manifest_value candidate_image_id "$manifest")"
  [[ "$image" =~ ^sha256:[0-9a-f]{64}$ ]] || die "superseded run candidate image is invalid: $(basename "$path")"
  declare -A seen=()
  while [[ "$revision" != "$CURRENT_PRODUCTION_REVISION" ]]; do
    [[ -z "${seen[$revision]+x}" ]] || die "successful rollout chain contains a cycle"
    seen["$revision"]=1
    next_path="$(successor_run_for_revision "$revision")" \
      || die "superseded run has no unique successful successor chain: $(basename "$path")"
    verify_run_dump "$next_path"
    next_revision="$(manifest_value candidate_revision "$next_path/manifest.env")"
    next_previous_image="$(manifest_value previous_image_id "$next_path/manifest.env")"
    next_image="$(manifest_value candidate_image_id "$next_path/manifest.env")"
    [[ "$next_revision" =~ ^[0-9a-f]{40}$ && "$next_revision" != "$revision" ]] \
      || die "successful successor has an invalid candidate revision: $(basename "$next_path")"
    [[ "$next_previous_image" == "$image" ]] \
      || die "successful successor image chain is discontinuous: $(basename "$next_path")"
    [[ "$next_image" =~ ^sha256:[0-9a-f]{64}$ && "$next_image" != "$image" ]] \
      || die "successful successor has an invalid candidate image: $(basename "$next_path")"
    revision="$next_revision"
    image="$next_image"
    hops=$((hops + 1))
    (( hops <= 64 )) || die "successful rollout chain is unexpectedly long"
  done
  (( hops > 0 )) || die "current production run cannot be retired as superseded"
}

retire_superseded_runs() {
  command -v sha256sum >/dev/null 2>&1 || die "sha256sum is unavailable"
  command -v awk >/dev/null 2>&1 || die "awk is unavailable"
  assert_positive_integer "$RETIRE_MIN_AGE_HOURS"
  check_baseline
  resolve_current_production_run

  local min_minutes=$(( RETIRE_MIN_AGE_HOURS * 60 ))
  local path manifest status candidate_revision previous_image_id rollback_tag tag_image references retired=0
  local -a retire_paths=() retire_tags=() retire_images=() retire_tag_present=()
  while IFS= read -r path; do
    [[ "$(cat "$path/.owner" 2>/dev/null || true)" == "sub2api-upgrade-v1" ]] || continue
    [[ "$path" != "$CURRENT_RUN_PATH" ]] || continue
    manifest="$path/manifest.env"
    [[ -f "$manifest" ]] || continue
    status="$(manifest_value status "$manifest")"
    [[ "$status" == "passed_pending_finalization" ]] || continue
    (( $(run_age_minutes "$path") >= min_minutes )) || continue
    candidate_revision="$(manifest_value candidate_revision "$manifest")"
    [[ "$candidate_revision" != "$CURRENT_PRODUCTION_REVISION" ]] || continue
    verify_run_dump "$path"
    assert_successor_chain_reaches_production "$path"

    previous_image_id="$(manifest_value previous_image_id "$manifest")"
    [[ "$previous_image_id" =~ ^sha256:[0-9a-f]{64}$ ]] || die "superseded run previous image id is invalid: $(basename "$path")"
    rollback_tag="$(manifest_value rollback_tag "$manifest")"
    [[ "$rollback_tag" =~ ^ghcr\.io/wesperez/sub2api:rollback-upgrade-[0-9]{8}T[0-9]{6}Z-[0-9a-f]{12}$ ]] \
      || die "superseded run has an unsafe rollback tag: $(basename "$path")"
    if docker image inspect "$rollback_tag" >/dev/null 2>&1; then
      tag_image="$(docker image inspect -f '{{.Id}}' "$rollback_tag")"
      [[ "$tag_image" == "$previous_image_id" ]] || die "superseded rollback tag points to an unexpected image: $rollback_tag"
      references="$(docker ps -aq --filter "ancestor=$rollback_tag")"
      [[ -z "$references" ]] || die "superseded rollback image is still referenced by a container: $rollback_tag"
      retire_tag_present+=(1)
    else
      retire_tag_present+=(0)
    fi
    retire_paths+=("$path")
    retire_tags+=("$rollback_tag")
    retire_images+=("$previous_image_id")
  done < <(find "$RUN_ROOT" -mindepth 1 -maxdepth 1 -type d -name 'upgrade-*' -print | sort)

  local i
  for i in "${!retire_paths[@]}"; do
    path="${retire_paths[$i]}"
    rollback_tag="${retire_tags[$i]}"
    previous_image_id="${retire_images[$i]}"
    if [[ "${retire_tag_present[$i]}" == 1 ]]; then
      if (( APPLY == 1 )); then
        tag_image="$(docker image inspect -f '{{.Id}}' "$rollback_tag")"
        [[ "$tag_image" == "$previous_image_id" ]] || die "superseded rollback tag changed before removal: $rollback_tag"
        references="$(docker ps -aq --filter "ancestor=$rollback_tag")"
        [[ -z "$references" ]] || die "superseded rollback image became referenced before removal: $rollback_tag"
        docker image rm "$rollback_tag" >/dev/null
        info "released superseded task-owned rollback tag: $rollback_tag"
      else
        info "would release superseded task-owned rollback tag: $rollback_tag"
      fi
    else
      info "superseded rollback tag is already absent: $rollback_tag"
    fi
    if (( APPLY == 1 )); then
      printf 'status=superseded\nsuperseded_at=%s\nsuperseded_by_run_id=%s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(basename "$CURRENT_RUN_PATH")" >> "$path/manifest.env"
    fi
    retired=$((retired + 1))
  done
  info "current production run: $(basename "$CURRENT_RUN_PATH"); superseded candidates: $retired"
}

finalize_run() {
  command -v sha256sum >/dev/null 2>&1 || die "sha256sum is unavailable"
  command -v awk >/dev/null 2>&1 || die "awk is unavailable"
  local path
  path="$(run_dir_for "$RUN_ID")"
  local manifest="$path/manifest.env"
  [[ -f "$manifest" ]] || die "run manifest is missing"
  local status
  status="$(manifest_value status "$manifest")"
  [[ "$status" == "passed_pending_finalization" || "$status" == "finalized" ]] || die "run is not an eligible successful rollout: $status"

  local age
  age="$(run_age_minutes "$path")"
  (( age >= MIN_AGE_MINUTES )) || die "run is only ${age}m old; preserve rollback evidence for at least ${MIN_AGE_MINUTES}m"

  local candidate_revision candidate_image_id expected_digest
  candidate_revision="$(manifest_value candidate_revision "$manifest")"
  candidate_image_id="$(manifest_value candidate_image_id "$manifest")"
  expected_digest="$(manifest_value expected_digest "$manifest")"
  [[ "$candidate_revision" =~ ^[0-9a-f]{40}$ ]] || die "run has no valid candidate revision"
  [[ "$candidate_image_id" =~ ^sha256:[0-9a-f]{64}$ ]] || die "run has no valid candidate image id"
  [[ "$expected_digest" =~ ^sha256:[0-9a-f]{64}$ ]] || die "run has no valid expected digest"
  local database_dump
  local database_dump_sha256
  database_dump="$(manifest_value database_dump "$manifest")"
  database_dump_sha256="$(manifest_value database_dump_sha256 "$manifest")"
  [[ "$database_dump" == "$path/postgres.dump" ]] || die "run manifest has an unexpected database dump path"
  [[ -s "$database_dump" ]] || die "run database dump is missing or empty"
  [[ "$database_dump_sha256" =~ ^[0-9a-f]{64}$ ]] || die "run database dump has no valid sha256"
  [[ "$(sha256sum "$database_dump" | awk '{print $1}')" == "$database_dump_sha256" ]] || die "run database dump sha256 does not match"
  local -a running_containers=()
  mapfile -t running_containers < <(docker ps -q --filter 'name=^/sub2api-prod$')
  [[ "${#running_containers[@]}" == "1" ]] || die "production application container is not uniquely running"
  local running_container="${running_containers[0]}"
  local running_image
  local running_revision
  running_image="$(docker inspect -f '{{.Image}}' "$running_container")"
  running_revision="$(docker image inspect -f '{{index .Config.Labels "org.opencontainers.image.revision"}}' "$running_image")"
  [[ "$running_image" == "$candidate_image_id" ]] || die "production image id differs from finalized candidate"
  [[ "$running_revision" == "$candidate_revision" ]] || die "production revision differs from finalized candidate"
  local running_repo_digests running_ref_name
  running_repo_digests="$(docker image inspect -f '{{json .RepoDigests}}' "$running_image")"
  jq -e --arg repo "$APP_IMAGE_REPOSITORY" --arg digest "$expected_digest" '
    type=="array" and ([.[] | select(.==($repo+"@"+$digest))] | length)==1
  ' >/dev/null <<<"$running_repo_digests" || die "production digest differs from finalized candidate"
  running_ref_name="$(docker image inspect -f '{{index .Config.Labels "org.opencontainers.image.ref.name"}}' "$running_image")"

  local promotion_run_id
  promotion_run_id="$(manifest_value promotion_run_id "$manifest")"
  if [[ -n "$promotion_run_id" ]]; then
    [[ "$promotion_run_id" =~ ^[0-9]+$ ]] || die "run has invalid promotion run id"
    [[ "$running_ref_name" == "debug" ]] || die "promoted production image content identity is not debug"
    local evidence_file evidence_sha promotion_file promotion_sha
    evidence_file="$(manifest_value verification_evidence_file "$manifest")"
    evidence_sha="$(manifest_value verification_evidence_sha256 "$manifest")"
    promotion_file="$(manifest_value promotion_verification_file "$manifest")"
    promotion_sha="$(manifest_value promotion_verification_sha256 "$manifest")"
    [[ "$evidence_file" == "$path/verification-release-evidence.json" && -f "$evidence_file" && ! -L "$evidence_file" ]] \
      || die "run release evidence copy is missing or unsafe"
    [[ "$promotion_file" == "$path/promotion-verification.json" && -f "$promotion_file" && ! -L "$promotion_file" ]] \
      || die "run promotion verification copy is missing or unsafe"
    [[ "$evidence_sha" =~ ^[0-9a-f]{64}$ && "$(sha256sum "$evidence_file" | awk '{print $1}')" == "$evidence_sha" ]] \
      || die "run release evidence checksum differs"
    [[ "$promotion_sha" =~ ^[0-9a-f]{64}$ && "$(sha256sum "$promotion_file" | awk '{print $1}')" == "$promotion_sha" ]] \
      || die "run promotion verification checksum differs"
    local plan_copy fixture_copy matrix_copy adapter_copy config_copy
    plan_copy="$path/verification-plan.json"
    fixture_copy="$path/verification-fixture-manifest.json"
    matrix_copy="$path/verification-matrix-catalog.tsv"
    adapter_copy="$path/verification-adapter-catalog.tsv"
    config_copy="$path/verification-config-fingerprint.json"
    local copy expected_copy_sha
    for copy in "$plan_copy" "$fixture_copy" "$matrix_copy" "$adapter_copy" "$config_copy"; do
      [[ -f "$copy" && ! -L "$copy" ]] || die "run verification input copy is missing or unsafe: $copy"
    done
    jq -e '.bindings.adapter_bundle_sha256|type=="string" and test("^[0-9a-f]{64}$")' \
      "$evidence_file" >/dev/null || die "run evidence has no valid adapter_bundle_sha256"
    while IFS=$'\t' read -r copy expected_copy_sha; do
      [[ "$expected_copy_sha" =~ ^[0-9a-f]{64}$ ]] || die "run verification input has no valid bound checksum: $copy"
      [[ "$(sha256sum "$copy" | awk '{print $1}')" == "$expected_copy_sha" ]] \
        || die "run verification input checksum differs: $copy"
    done < <(jq -r --arg plan "$plan_copy" --arg fixture "$fixture_copy" --arg matrix "$matrix_copy" \
      --arg adapter "$adapter_copy" --arg config "$config_copy" '
      [[$plan,.bindings.plan_sha256],
       [$fixture,.bindings.fixture_manifest_sha256],
       [$matrix,.bindings.matrix_catalog_sha256],
       [$adapter,.bindings.adapter_catalog_sha256],
       [$config,.bindings.config_fingerprint_document_sha256]][] | @tsv
    ' "$evidence_file")
    local evidence_source_run promotion_source_run
    evidence_source_run="$(jq -r '.bindings.source_run_id // empty | tostring' "$evidence_file")"
    promotion_source_run="$(jq -r '.promotion.source_run_id // empty | tostring' "$promotion_file")"
    [[ "$evidence_source_run" =~ ^[0-9]+$ && "$promotion_source_run" == "$evidence_source_run" ]] \
      || die "promotion source run differs from the sealed R0-1 workflow run"
    jq -e --arg run "$promotion_run_id" --arg revision "$candidate_revision" --arg digest "$expected_digest" \
      --arg evidence "$evidence_sha" --arg source_run "$evidence_source_run" '
      (.promotion.promotion_run_id|tostring)==$run
      and .promotion.revision==$revision
      and .promotion.source_digest==$digest
      and .promotion.target_digest==$digest
      and (.promotion.source_run_id|tostring)==$source_run
      and .promotion.verification_evidence_sha256==$evidence
      and .promotion.evidence_binding_mode=="recorded-hash-production-apply-verifies-local-file"
      and .image.pulled==true and .image.revision==$revision and .image.digest==$digest
      and .image.ref_name=="debug"
    ' "$promotion_file" >/dev/null || die "run promotion verification no longer matches production"
  else
    [[ "$running_ref_name" == "mine" ]] || die "legacy rollout image is not labeled mine"
  fi
  local post_confirm_status
  post_confirm_status="$(manifest_value post_confirm_status "$manifest")"
  if [[ "$status" == "passed_pending_finalization" || -n "$post_confirm_status" ]]; then
    verify_post_confirmation "$path" "$manifest" "$candidate_revision" "$expected_digest"
  fi
  check_baseline

  local rollback_tag
  rollback_tag="$(manifest_value rollback_tag "$manifest")"
  [[ "$rollback_tag" =~ ^ghcr\.io/wesperez/sub2api:rollback-upgrade-[0-9]{8}T[0-9]{6}Z-[0-9a-f]{12}$ ]] || die "run has an unsafe rollback tag"
  if docker image inspect "$rollback_tag" >/dev/null 2>&1; then
    local references
    references="$(docker ps -aq --filter "ancestor=$rollback_tag")"
    [[ -z "$references" ]] || die "rollback image is still referenced by a container"
    if (( APPLY == 1 )); then
      docker image rm "$rollback_tag" >/dev/null
      info "released task-owned rollback tag: $rollback_tag"
    else
      info "would release task-owned rollback tag: $rollback_tag"
    fi
  else
    info "rollback tag is already absent: $rollback_tag"
  fi

  if (( APPLY == 1 )) && [[ "$status" != "finalized" ]]; then
    printf 'status=finalized\nfinalized_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$manifest"
  fi
  info "preserved database dump, .env snapshot, Compose snapshot, and manifest in $path"
}

list_runs() {
  if [[ ! -d "$RUN_ROOT" ]]; then
    info "no skill-owned run root exists"
    return
  fi
  printf 'run_id\tstatus\tage_minutes\tcandidate_revision\tdump\n'
  local path manifest status age revision dump dump_state
  while IFS= read -r path; do
    [[ "$(cat "$path/.owner" 2>/dev/null || true)" == "sub2api-upgrade-v1" ]] || continue
    manifest="$path/manifest.env"
    [[ -f "$manifest" ]] || continue
    status="$(manifest_value status "$manifest")"
    age="$(run_age_minutes "$path")"
    revision="$(manifest_value candidate_revision "$manifest")"
    dump="$(manifest_value database_dump "$manifest")"
    dump_state="missing"
    [[ -n "$dump" && -s "$dump" ]] && dump_state="present"
    printf '%s\t%s\t%s\t%s\t%s\n' "$(basename "$path")" "$status" "$age" "${revision:0:12}" "$dump_state"
  done < <(find "$RUN_ROOT" -mindepth 1 -maxdepth 1 -type d -name 'upgrade-*' -print | sort -r)
}

eligible_prune_run() {
  local path="$1"
  [[ "$(cat "$path/.owner" 2>/dev/null || true)" == "sub2api-upgrade-v1" ]] || return 1
  local status
  status="$(manifest_value status "$path/manifest.env" 2>/dev/null || true)"
  [[ "$status" == "finalized" || "$status" == "superseded" ]] || return 1
  local min_minutes=$(( PRUNE_MIN_AGE_HOURS * 60 ))
  (( $(run_age_minutes "$path") >= min_minutes ))
}

prune_runs() {
  [[ -d "$RUN_ROOT" ]] || { info "no skill-owned run root exists"; return 0; }
  assert_positive_integer "$KEEP_RUNS"
  assert_positive_integer "$PRUNE_MIN_AGE_HOURS"
  check_baseline
  resolve_current_production_run

  local -a all_runs=()
  local path
  while IFS= read -r path; do
    all_runs+=("$path")
  done < <(find "$RUN_ROOT" -mindepth 1 -maxdepth 1 -type d -name 'upgrade-*' -printf '%f\n' | sort -r)

  local index=0
  # The currently running production revision always consumes one retention slot.
  local retained=1
  local pruned=0
  for path in "${all_runs[@]}"; do
    path="$RUN_ROOT/$path"
    if [[ "$path" == "$CURRENT_RUN_PATH" ]]; then
      info "preserving current production recovery run: $(basename "$path")"
      continue
    fi
    if ! eligible_prune_run "$path"; then
      continue
    fi
    if (( retained < KEEP_RUNS )); then
      retained=$((retained + 1))
      continue
    fi
    index=$((index + 1))
    if (( APPLY == 1 )); then
      [[ "$(run_dir_for "$(basename "$path")")" == "$path" ]] || die "owned run changed during prune"
      rm -rf -- "$path"
      info "removed expired task-owned recovery run: $(basename "$path")"
    else
      info "would remove expired task-owned recovery run: $(basename "$path")"
    fi
    pruned=$((pruned + 1))
  done
  info "retained recovery runs including current production: $retained; prune candidates: $pruned"
}

parse_args() {
  while (( $# > 0 )); do
    case "$1" in
      --run-id)
        (( $# >= 2 )) || die "--run-id requires a value"
        [[ -z "$ACTION" ]] || die "select only one action"
        ACTION="finalize"
        RUN_ID="$2"
        shift
        ;;
      --prune)
        [[ -z "$ACTION" ]] || die "select only one action"
        ACTION="prune"
        ;;
      --retire-superseded)
        [[ -z "$ACTION" ]] || die "select only one action"
        ACTION="retire-superseded"
        ;;
      --list)
        [[ -z "$ACTION" ]] || die "select only one action"
        ACTION="list"
        ;;
      --apply)
        APPLY=1
        ;;
      --min-age-minutes)
        (( $# >= 2 )) || die "--min-age-minutes requires a value"
        MIN_AGE_MINUTES="$2"
        shift
        ;;
      --min-age-hours)
        (( $# >= 2 )) || die "--min-age-hours requires a value"
        PRUNE_MIN_AGE_HOURS="$2"
        RETIRE_MIN_AGE_HOURS="$2"
        shift
        ;;
      --keep)
        (( $# >= 2 )) || die "--keep requires a value"
        KEEP_RUNS="$2"
        shift
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        die "unknown argument: $1"
        ;;
    esac
    shift
  done
  [[ -n "$ACTION" ]] || die "select --list, --run-id, --retire-superseded, or --prune"
  if [[ "$ACTION" == "finalize" ]]; then
    assert_positive_integer "$MIN_AGE_MINUTES"
  elif [[ "$ACTION" == "list" && "$APPLY" == "1" ]]; then
    die "--apply is not valid with --list"
  elif [[ "$ACTION" == "retire-superseded" ]]; then
    assert_positive_integer "$RETIRE_MIN_AGE_HOURS"
  fi
}

main() {
  parse_args "$@"
  if [[ "$ACTION" == "finalize" ]]; then
    finalize_run
  elif [[ "$ACTION" == "list" ]]; then
    list_runs
  elif [[ "$ACTION" == "retire-superseded" ]]; then
    retire_superseded_runs
  else
    prune_runs
  fi
}

main "$@"
