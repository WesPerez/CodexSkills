#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

TESTS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$TESTS_DIR/common.sh"
SCRIPT="$SCRIPTS_DIR/confirm-production-upgrade.sh"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
export SUB2API_UPGRADE_TEST_MODE=1
export SUB2API_POST_CONFIRM_TEST_RUN_ROOT="$TMP/runs"
export SUB2API_POST_CONFIRM_TEST_SOURCE_REPO="$TMP/repo"
export SUB2API_POST_CONFIRM_TEST_PROD_DEPLOY="$TMP/prod"
export SUB2API_POST_CONFIRM_TEST_DEBUG_DEPLOY="$TMP/debug"
export SUB2API_POST_CONFIRM_TEST_DOCKER="$TMP/bin/docker"
export SUB2API_POST_CONFIRM_TEST_CURL="$TMP/bin/curl"
export SUB2API_POST_CONFIRM_TEST_GIT="$TMP/bin/git"
export SUB2API_POST_CONFIRM_TEST_PREFLIGHT="$TMP/bin/preflight"
export SUB2API_POST_CONFIRM_TEST_DEBUG_LOCK="$TMP/debug-adapter.lock"

RUN_ID="upgrade-20260724T035638Z-${REV:0:12}"
mkdir -p "$TMP/bin" "$TMP/repo" "$TMP/prod" "$TMP/debug" "$TMP/runs"
touch "$TMP/prod/docker-compose.yml" "$TMP/debug/docker-compose.yml"

cat > "$TMP/bin/preflight" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ "${PREFLIGHT_FAIL:-0}" != 1 ]]
SH
chmod 0755 "$TMP/bin/preflight"

cat > "$TMP/bin/curl" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ "${CURL_FAIL:-0}" != 1 ]]
case " $* " in
  *'/health'*) printf '%s\n' '{"status":"ok"}' ;;
  *) printf '%s\n' '{"status":"ready"}' ;;
esac
SH
chmod 0755 "$TMP/bin/curl"

cat > "$TMP/bin/git" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
if [[ "${GIT_DRIFT:-0}" == 1 ]]; then
  printf '%s\t%s\n' "${TEST_REV}X" refs/heads/mine
  printf '%s\t%s\n' "${TEST_REV}" refs/heads/debug
else
  printf '%s\t%s\n' "${TEST_REV}" refs/heads/mine
  printf '%s\t%s\n' "${TEST_REV}" refs/heads/debug
fi
SH
chmod 0755 "$TMP/bin/git"

cat > "$TMP/bin/docker" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >> "${DOCKER_LOG}"
args=" $* "
if [[ "$args" == *' ps '* ]]; then
  printf '%s\n' cid-prod
  exit 0
fi
if [[ "${1:-}" == inspect ]]; then
  printf '%s\n' "${TEST_IMAGE}"
  exit 0
fi
if [[ "$args" == *' image inspect '* ]]; then
  case "$*" in
    *org.opencontainers.image.revision*) printf '%s\n' "${DOCKER_REV:-$TEST_REV}" ;;
    *org.opencontainers.image.ref.name*) printf '%s\n' debug ;;
    *RepoDigests*) printf '["ghcr.io/wesperez/sub2api@%s"]\n' "${TEST_DIGEST}" ;;
    *) printf '%s\n' "${TEST_IMAGE}" ;;
  esac
  exit 0
fi
if [[ "$args" == *' compose '* && "$args" == *' logs '* ]]; then
  if [[ -n "${LOG_CONTENT+x}" ]]; then
    printf '%s' "$LOG_CONTENT"
  else
    printf '%s\n' 'healthy production log line'
  fi
  exit 0
fi
if [[ "$args" == *' compose '* && "$args" == *' stop '* ]]; then
  printf '%s\n' stopped >> "${STOP_LOG}"
  exit 0
fi
exit 99
SH
chmod 0755 "$TMP/bin/docker"

export TEST_REV="$REV"
export TEST_DIGEST="$DIGEST"
export TEST_IMAGE="sha256:$(printf 'd%.0s' {1..64})"
export DOCKER_LOG="$TMP/docker.log"
export STOP_LOG="$TMP/stop.log"

make_run() {
  local name="$1"
  local dir="$TMP/runs/$RUN_ID"
  rm -rf -- "$dir"
  mkdir -p "$dir"
  printf 'sub2api-upgrade-v1\n' > "$dir/.owner"
  printf 'fixture dump\n' > "$dir/postgres.dump"
  local dump_sha
  dump_sha="$(sha256sum "$dir/postgres.dump" | awk '{print $1}')"
  cat > "$dir/manifest.env" <<EOF
run_id=$RUN_ID
candidate_revision=$REV
expected_digest=$DIGEST
candidate_image_id=$TEST_IMAGE
passed_at=2026-07-24T03:57:23Z
database_dump=$dir/postgres.dump
database_dump_sha256=$dump_sha
status=passed_pending_finalization
EOF
  jq -n --argjson providers '["openai","grok"]' '{selection:{active_inventory:{present:true,providers:$providers}}}' > "$dir/verification-plan.json"
}

evidence() {
  local file="$1" provider="$2"
  jq -n --arg revision "$REV" --arg digest "$DIGEST" --arg run "$RUN_ID" --arg provider "$provider" '
    {schema_version:1,kind:"production-live-confirmation",revision:$revision,digest:$digest,run_id:$run,provider:$provider,
     client:{type:"official-codex",version:"test"},request:{model:"test-model",task_class:"structured-smoke"},
     result:{passed:true,http_or_transport_ok:true,semantic_ok:true,observed_at:"2026-07-24T04:01:00Z"},
     assertions:[{name:"meaningful_completion",passed:true}],verifier:"test-operator",
     procedure:"Official Codex completed a meaningful structured production smoke request."}' > "$file"
}

run_confirm() {
  bash "$SCRIPT" --run-id "$RUN_ID" --canary-evidence "$TMP/openai.json" --canary-evidence "$TMP/grok.json" "$@"
}

make_run base
evidence "$TMP/openai.json" openai
evidence "$TMP/grok.json" grok
assert_ok "two-providers-pass" run_confirm --json
BASE="$TMP/runs/$RUN_ID"
jq -e '.status=="passed" and .providers_required==["grok","openai"] and .providers_confirmed==["grok","openai"] and (.canaries|map(.provider))==["grok","openai"] and .log_window.fatal_hits==0' "$BASE/post-confirm/confirmation.json" >/dev/null
[[ -f "$BASE/post-confirm/attempt-001/log-window.raw" ]]
[[ "$(stat -c %a "$BASE/post-confirm/attempt-001/log-window.raw")" == 600 ]]
! grep -q 'healthy production log line' "$TMP/docker.log"
while IFS=$'\t' read -r provider path expected_sha; do
  [[ "$(sha256sum "$BASE/post-confirm/attempt-001/$path" | awk '{print $1}')" == "$expected_sha" ]]
done < <(jq -r '.canaries[] | [.provider,.path,.sha256] | @tsv' "$BASE/post-confirm/confirmation.json")

make_run required-exact
assert_ok "required-provider-exact" bash "$SCRIPT" --run-id "$RUN_ID" --require-providers ' openai, grok ' \
  --canary-evidence "$TMP/openai.json" --canary-evidence "$TMP/grok.json"
jq -e '.providers_required==["grok","openai"] and (.canaries|map(.provider))==["grok","openai"]' "$BASE/post-confirm/confirmation.json" >/dev/null

make_run narrowed
assert_fail "required-provider-cannot-narrow" bash "$SCRIPT" --run-id "$RUN_ID" --require-providers 'openai' --canary-evidence "$TMP/openai.json"

assert_fail "missing-provider" bash "$SCRIPT" --run-id "$RUN_ID" --canary-evidence "$TMP/openai.json"

make_run revision-drift
export DOCKER_REV="$(printf 'e%.0s' {1..40})"
assert_fail "revision-drift" run_confirm
unset DOCKER_REV

make_run fatal-log
export LOG_CONTENT='panic: production failure response.failed'
assert_fail "fatal-log" run_confirm
unset LOG_CONTENT

make_run placeholder
jq '.procedure="TODO replace me with a real canary procedure"' "$TMP/openai.json" > "$TMP/placeholder.json"
assert_fail "placeholder-procedure" bash "$SCRIPT" --run-id "$RUN_ID" --canary-evidence "$TMP/placeholder.json" --canary-evidence "$TMP/grok.json"

make_run forbidden-procedure
jq '.procedure="A TestConnection request was used instead of an official client flow."' "$TMP/openai.json" > "$TMP/forbidden.json"
assert_fail "forbidden-procedure-normalized" bash "$SCRIPT" --run-id "$RUN_ID" --canary-evidence "$TMP/forbidden.json" --canary-evidence "$TMP/grok.json"

make_run pre-switch
jq '.result.observed_at="2026-07-24T03:57:22Z"' "$TMP/openai.json" > "$TMP/pre-switch.json"
assert_fail "pre-switch-evidence" bash "$SCRIPT" --run-id "$RUN_ID" --canary-evidence "$TMP/pre-switch.json" --canary-evidence "$TMP/grok.json"

make_run empty-log
export LOG_CONTENT=''
assert_ok "empty-log-is-a-valid-clean-window" run_confirm
unset LOG_CONTENT
jq -e '.log_window.empty==true and .log_window.byte_count==0 and .log_window.fatal_hits==0 and (.stop_debug|type)=="boolean"' \
  "$BASE/post-confirm/confirmation.json" >/dev/null
grep -Fq "post_confirm_file=$BASE/post-confirm/confirmation.json" "$BASE/manifest.env"

make_run attempts
assert_ok "attempt-one" run_confirm
assert_ok "new-attempt" run_confirm
[[ -f "$BASE/post-confirm/attempt-001/confirmation.json" ]]
[[ -f "$BASE/post-confirm/attempt-002/confirmation.json" ]]
[[ "$(awk -F= '$1=="post_confirm_attempt"{v=$2} END{print v}' "$BASE/manifest.env")" == 2 ]]

make_run stop-debug
assert_ok "stop-debug" run_confirm --stop-debug
[[ "$(cat "$STOP_LOG")" == stopped ]]
grep -Fq ' stop' "$DOCKER_LOG"
! grep -Eq ' compose .* (down|rm|delete)' "$DOCKER_LOG"

make_run stop-lock
exec 7>"$TMP/debug-adapter.lock"
flock -n 7
assert_fail "stop-debug-lock-held" run_confirm --stop-debug
exec 7>&-

summary
