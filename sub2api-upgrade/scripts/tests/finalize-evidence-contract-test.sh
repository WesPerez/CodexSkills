#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

TESTS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCRIPT="$(cd -- "$TESTS_DIR/.." && pwd -P)/finalize-sub2api-upgrade.sh"

python3 - "$SCRIPT" <<'PY'
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text(encoding="utf-8")
required = [
    "candidate_image_id",
    "expected_digest",
    "production image id differs from finalized candidate",
    "production digest differs from finalized candidate",
    "verification-release-evidence.json",
    "verification-adapter-catalog.tsv",
    "adapter_catalog_sha256",
    "adapter_bundle_sha256",
    "promotion source run differs from the sealed R0-1 workflow run",
    "recorded-hash-production-apply-verifies-local-file",
    "promotion-verification.json",
    "promotion_verification_sha256",
    '.image.ref_name=="debug"',
    "run promotion verification no longer matches production",
    "assert_successor_chain_reaches_production",
    "superseded rollback tag points to an unexpected image",
    "released superseded task-owned rollback tag",
    "status=superseded",
    '[[ "$status" == "finalized" || "$status" == "superseded" ]]',
    "passed_at",
    "verify_post_confirmation",
    "run post-confirm summary checksum differs",
    "run post-confirm log window checksum differs",
    "run post-confirm canary checksum differs",
    "run has no passed post-switch production confirmation",
    "preserving current production recovery run",
]
missing = [item for item in required if item not in text]
if missing:
    for item in missing:
        print("FAIL: finalize missing evidence gate", item)
    raise SystemExit(1)

finalize_start = text.find("finalize_run()")
retire_start = text.find("retire_superseded_runs()")
list_start = text.find("list_runs()")
if min(finalize_start, retire_start, list_start) < 0:
    print("FAIL: finalize action boundaries are missing")
    raise SystemExit(1)
finalize_text = text[finalize_start:list_start]
retire_text = text[retire_start:finalize_start]
evidence_gate = finalize_text.find("run promotion verification no longer matches production")
post_confirm_gate = finalize_text.find("verify_post_confirmation")
rollback_release = finalize_text.find('docker image rm "$rollback_tag"')
if min(evidence_gate, post_confirm_gate, rollback_release) < 0 or not (
    evidence_gate < post_confirm_gate < rollback_release
):
    print("FAIL: finalize releases rollback tag before digest/post-confirm verification")
    raise SystemExit(1)
chain_gate = retire_text.find("assert_successor_chain_reaches_production")
tag_gate = retire_text.find("superseded rollback tag points to an unexpected image")
retire_release = retire_text.find('docker image rm "$rollback_tag"')
if min(chain_gate, tag_gate, retire_release) < 0 or not (chain_gate < tag_gate < retire_release):
    print("FAIL: superseded retirement releases rollback tag before chain/image verification")
    raise SystemExit(1)
print("PASS: finalize digest/evidence contract")
PY
