#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

TESTS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCRIPT="$(cd -- "$TESTS_DIR/.." && pwd -P)/finalize-sub2api-upgrade.sh"
TMP="$(mktemp -d /tmp/finalize-superseded-test.XXXXXX)"
trap 'rm -rf -- "$TMP"' EXIT

RUN_ROOT="$TMP/runs"
BIN="$TMP/bin"
ROUTER_CONFIG="$TMP/router.conf"
DOCKER_RM_LOG="$TMP/docker-rm.log"
mkdir -p "$RUN_ROOT" "$BIN"
printf 'upstream backend {\n    server 127.0.0.1:13083;\n}\n' > "$ROUTER_CONFIG"

REV_A="$(printf '1%.0s' {1..40})"
REV_B="$(printf '2%.0s' {1..40})"
REV_C="$(printf '3%.0s' {1..40})"
REV_D="$(printf '4%.0s' {1..40})"
IMG_A="sha256:$(printf 'a%.0s' {1..64})"
IMG_B="sha256:$(printf 'b%.0s' {1..64})"
IMG_C="sha256:$(printf 'c%.0s' {1..64})"
IMG_D="sha256:$(printf 'e%.0s' {1..64})"
DIGEST="sha256:$(printf 'd%.0s' {1..64})"
RUN_OLD="upgrade-20200101T000000Z-${REV_B:0:12}"
RUN_CURRENT="upgrade-20200102T000000Z-${REV_C:0:12}"
RUN_NEWER="upgrade-20200103T000000Z-${REV_D:0:12}"
TAG_OLD="ghcr.io/wesperez/sub2api:rollback-$RUN_OLD"

make_run() {
  local run_id="$1" status="$2" previous_revision="$3" candidate_revision="$4"
  local previous_image="$5" candidate_image="$6" expected_digest="$7"
  local dir="$RUN_ROOT/$run_id" dump_sha
  mkdir -p "$dir"
  printf 'sub2api-upgrade-v1\n' > "$dir/.owner"
  printf 'dump for %s\n' "$run_id" > "$dir/postgres.dump"
  dump_sha="$(sha256sum "$dir/postgres.dump" | awk '{print $1}')"
  {
    printf 'run_id=%s\n' "$run_id"
    printf 'created_at=2020-01-01T00:00:00Z\n'
    printf 'previous_revision=%s\n' "$previous_revision"
    printf 'candidate_revision=%s\n' "$candidate_revision"
    printf 'previous_image_id=%s\n' "$previous_image"
    printf 'candidate_image_id=%s\n' "$candidate_image"
    printf 'expected_digest=%s\n' "$expected_digest"
    printf 'database_dump=%s/postgres.dump\n' "$dir"
    printf 'database_dump_sha256=%s\n' "$dump_sha"
    printf 'rollback_tag=ghcr.io/wesperez/sub2api:rollback-%s\n' "$run_id"
    printf 'passed_at=2020-01-02T00:00:00Z\n'
    printf 'status=%s\n' "$status"
  } > "$dir/manifest.env"
}

make_run "$RUN_OLD" passed_pending_finalization "$REV_A" "$REV_B" "$IMG_A" "$IMG_B" ""
make_run "$RUN_CURRENT" finalized "$REV_B" "$REV_C" "$IMG_B" "$IMG_C" "$DIGEST"

cat > "$BIN/curl" <<'STUB'
#!/usr/bin/env bash
url="${!#}"
if [[ "$url" == */ready ]]; then
  printf '%s\n' '{"status":"ready"}'
else
  printf '%s\n' '{"status":"ok"}'
fi
STUB

cat > "$BIN/docker" <<STUB
#!/usr/bin/env bash
set -Eeuo pipefail
cmd="\$*"
case "\$cmd" in
  'ps -q --filter name=^/sub2api-prod$') printf '%s\n' current-container ;;
  'inspect -f {{.Image}} current-container') printf '%s\n' '$IMG_C' ;;
  image\ inspect\ -f*org.opencontainers.image.revision*'$IMG_C') printf '%s\n' '$REV_C' ;;
  image\ inspect\ -f*RepoDigests*'$IMG_C') printf '%s\n' '["ghcr.io/wesperez/sub2api@$DIGEST"]' ;;
  'image inspect $TAG_OLD') exit 0 ;;
  image\ inspect\ -f*'{{.Id}}'*'$TAG_OLD') printf '%s\n' '$IMG_A' ;;
  'ps -aq --filter ancestor=$TAG_OLD') exit 0 ;;
  'image rm $TAG_OLD') printf '%s\n' '$TAG_OLD' >> '$DOCKER_RM_LOG' ;;
  *) printf 'unexpected docker invocation: %s\n' "\$cmd" >&2; exit 1 ;;
esac
STUB
chmod +x "$BIN/curl" "$BIN/docker"

run_script() {
  env SUB2API_UPGRADE_TEST_MODE=1 \
    SUB2API_FINALIZE_RUN_ROOT="$RUN_ROOT" \
    SUB2API_FINALIZE_ROUTER_CONFIG="$ROUTER_CONFIG" \
    SUB2API_FINALIZE_PUBLIC_HOST=test.invalid \
    PATH="$BIN:$PATH" \
    bash "$SCRIPT" "$@"
}

list_output="$(run_script --list)"
age="$(awk -F'\t' -v run="$RUN_CURRENT" '$1==run {print $3}' <<<"$list_output")"
[[ "$age" =~ ^[0-9]+$ && "$age" -gt 1000 ]] || {
  printf 'FAIL: run age did not use passed_at\n' >&2
  exit 1
}

dry_output="$(run_script --retire-superseded --min-age-hours 1)"
grep -Fq "would release superseded task-owned rollback tag: $TAG_OLD" <<<"$dry_output"
[[ "$(awk -F= '$1=="status"{v=$2} END{print v}' "$RUN_ROOT/$RUN_OLD/manifest.env")" == "passed_pending_finalization" ]]

run_script --retire-superseded --min-age-hours 1 --apply >/dev/null
grep -Fxq "$TAG_OLD" "$DOCKER_RM_LOG"
[[ "$(awk -F= '$1=="status"{v=$2} END{print v}' "$RUN_ROOT/$RUN_OLD/manifest.env")" == "superseded" ]]
grep -Fq "superseded_by_run_id=$RUN_CURRENT" "$RUN_ROOT/$RUN_OLD/manifest.env"

# A newer directory that is not the running production revision must not displace
# the current production recovery run from the retention set.
make_run "$RUN_NEWER" finalized "$REV_A" "$REV_D" "$IMG_A" "$IMG_D" ""
prune_output="$(run_script --prune --keep 1 --min-age-hours 1)"
grep -Fq "preserving current production recovery run: $RUN_CURRENT" <<<"$prune_output"
grep -Fq "would remove expired task-owned recovery run: $RUN_OLD" <<<"$prune_output"
grep -Fq "would remove expired task-owned recovery run: $RUN_NEWER" <<<"$prune_output"
run_script --prune --keep 1 --min-age-hours 1 --apply >/dev/null
[[ ! -e "$RUN_ROOT/$RUN_OLD" && ! -e "$RUN_ROOT/$RUN_NEWER" && -d "$RUN_ROOT/$RUN_CURRENT" ]]

printf '%s\n' 'PASS: finalize superseded chain, age anchor, and prune contract'
