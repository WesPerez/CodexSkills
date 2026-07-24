#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

TESTS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$TESTS_DIR/common.sh"
SCRIPT="$SCRIPTS_DIR/finalize-sub2api-upgrade.sh"
TMP="$(mktemp -d /tmp/finalize-post-confirm-test.XXXXXX)"
trap 'rm -rf -- "$TMP"' EXIT

RUN_ROOT="$TMP/runs"
BIN="$TMP/bin"
ROUTER_CONFIG="$TMP/router.conf"
RUN_ID="upgrade-20260724T035638Z-${REV:0:12}"
RUN_DIR="$RUN_ROOT/$RUN_ID"
IMAGE="sha256:$(printf 'd%.0s' {1..64})"
ROLLBACK_TAG="ghcr.io/wesperez/sub2api:rollback-$RUN_ID"
mkdir -p "$RUN_ROOT" "$BIN"
printf 'upstream backend {\n    server 127.0.0.1:13083;\n}\n' > "$ROUTER_CONFIG"

cat > "$BIN/curl" <<'SH'
#!/usr/bin/env bash
case "${!#}" in
  */ready) printf '%s\n' '{"status":"ready"}' ;;
  *) printf '%s\n' '{"status":"ok"}' ;;
esac
SH

cat > "$BIN/docker" <<SH
#!/usr/bin/env bash
set -Eeuo pipefail
cmd="\$*"
case "\$cmd" in
  'ps -q --filter name=^/sub2api-prod$') printf '%s\n' current-container ;;
  'inspect -f {{.Image}} current-container') printf '%s\n' '$IMAGE' ;;
  image\ inspect\ -f*org.opencontainers.image.revision*'$IMAGE') printf '%s\n' '$REV' ;;
  image\ inspect\ -f*RepoDigests*'$IMAGE') printf '%s\n' '["ghcr.io/wesperez/sub2api@$DIGEST"]' ;;
  image\ inspect\ -f*org.opencontainers.image.ref.name*'$IMAGE') printf '%s\n' mine ;;
  'image inspect $ROLLBACK_TAG') exit 0 ;;
  'ps -aq --filter ancestor=$ROLLBACK_TAG') exit 0 ;;
  *) printf 'unexpected docker invocation: %s\n' "\$cmd" >&2; exit 1 ;;
esac
SH
chmod 0755 "$BIN/curl" "$BIN/docker"

run_script() {
  env SUB2API_UPGRADE_TEST_MODE=1 \
    SUB2API_FINALIZE_RUN_ROOT="$RUN_ROOT" \
    SUB2API_FINALIZE_ROUTER_CONFIG="$ROUTER_CONFIG" \
    SUB2API_FINALIZE_PUBLIC_HOST=test.invalid \
    PATH="$BIN:$PATH" \
    bash "$SCRIPT" --run-id "$RUN_ID" --min-age-minutes 1
}

make_run() {
  local with_confirmation="${1:-1}" dump_sha
  rm -rf -- "$RUN_DIR"
  mkdir -p "$RUN_DIR"
  printf 'sub2api-upgrade-v1\n' > "$RUN_DIR/.owner"
  printf 'fixture dump\n' > "$RUN_DIR/postgres.dump"
  dump_sha="$(sha256sum "$RUN_DIR/postgres.dump" | awk '{print $1}')"
  cat > "$RUN_DIR/manifest.env" <<EOF
run_id=$RUN_ID
created_at=2026-07-24T03:56:38Z
previous_revision=$(printf 'a%.0s' {1..40})
candidate_revision=$REV
previous_image_id=sha256:$(printf 'e%.0s' {1..64})
candidate_image_id=$IMAGE
expected_digest=$DIGEST
database_dump=$RUN_DIR/postgres.dump
database_dump_sha256=$dump_sha
rollback_tag=$ROLLBACK_TAG
passed_at=2026-07-24T03:57:23Z
status=passed_pending_finalization
EOF
  (( with_confirmation )) || return 0

  local attempt="$RUN_DIR/post-confirm/attempt-001" canary_sha log_sha confirmation_sha
  mkdir -p "$attempt/canary"
  jq -n --arg revision "$REV" --arg digest "$DIGEST" --arg run "$RUN_ID" '
    {schema_version:1,kind:"production-live-confirmation",revision:$revision,digest:$digest,run_id:$run,provider:"openai",
     client:{type:"official-codex",version:"test"},request:{model:"test-model",task_class:"structured-smoke"},
     result:{passed:true,http_or_transport_ok:true,semantic_ok:true,observed_at:"2026-07-24T03:58:19Z"},
     assertions:[{name:"meaningful_completion",passed:true}],verifier:"test-operator",
     procedure:"Official Codex completed a meaningful structured production smoke request."}' \
    > "$attempt/canary/openai.json"
  canary_sha="$(sha256sum "$attempt/canary/openai.json" | awk '{print $1}')"
  : > "$attempt/log-window.raw"
  log_sha="$(sha256sum "$attempt/log-window.raw" | awk '{print $1}')"
  jq -n --arg run "$RUN_ID" --arg revision "$REV" --arg digest "$DIGEST" --arg canary_sha "$canary_sha" --arg log_sha "$log_sha" '
    {schema_version:1,kind:"production-post-confirmation",status:"passed",run_id:$run,revision:$revision,digest:$digest,
     attempt:1,confirmed_at:"2026-07-24T04:02:00Z",providers_required:["openai"],providers_confirmed:["openai"],
     canaries:[{provider:"openai",path:"canary/openai.json",sha256:$canary_sha}],
     log_window:{collected:true,scope:"sub2api",project:"sub2api-prod",since:"2026-07-24T03:57:23Z",until:"2026-07-24T04:02:00Z",path:"log-window.raw",sha256:$log_sha,compose_file:"/tmp/test/docker-compose.yml",raw_printed:false,fatal_hits:0,empty:true,byte_count:0,line_count:0},
     checks:{exact_revision_digest:true,origin_heads_match:true,preflight_or_health:true},stop_debug:false,
     raw_model_request_executed:false,test_connection_used:false}' > "$attempt/confirmation.json"
  mkdir -p "$RUN_DIR/post-confirm"
  cp "$attempt/confirmation.json" "$RUN_DIR/post-confirm/confirmation.json"
  confirmation_sha="$(sha256sum "$RUN_DIR/post-confirm/confirmation.json" | awk '{print $1}')"
  cat >> "$RUN_DIR/manifest.env" <<EOF
post_confirm_status=passed
post_confirm_at=2026-07-24T04:02:00Z
post_confirm_attempt=1
post_confirm_sha256=$confirmation_sha
post_confirm_log_window_sha256=$log_sha
post_confirm_dir=$attempt
post_confirm_file=$RUN_DIR/post-confirm/confirmation.json
EOF
}

rehash_confirmation() {
  local attempt="$RUN_DIR/post-confirm/attempt-001" sha
  cp "$attempt/confirmation.json" "$RUN_DIR/post-confirm/confirmation.json"
  sha="$(sha256sum "$RUN_DIR/post-confirm/confirmation.json" | awk '{print $1}')"
  printf 'post_confirm_sha256=%s\n' "$sha" >> "$RUN_DIR/manifest.env"
}

make_run 1
assert_ok "valid-post-confirmation" run_script

make_run 0
assert_fail "missing-post-confirmation" run_script

make_run 1
printf '\n' >> "$RUN_DIR/post-confirm/attempt-001/canary/openai.json"
assert_fail "tampered-canary" run_script

make_run 1
jq '.canaries[0].path="../openai.json"' "$RUN_DIR/post-confirm/attempt-001/confirmation.json" > "$TMP/confirmation.json"
mv "$TMP/confirmation.json" "$RUN_DIR/post-confirm/attempt-001/confirmation.json"
rehash_confirmation
assert_fail "unsafe-canary-path" run_script

make_run 1
printf 'panic: changed log\n' > "$RUN_DIR/post-confirm/attempt-001/log-window.raw"
assert_fail "tampered-log-window" run_script

summary
