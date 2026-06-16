#!/usr/bin/env bash
#
# smoke_test.sh — end-to-end smoke test for the TR TUF Trust Distribution
# repository at tuf.thomsonreuters.com.
#
# This test is the minimum proof that the published repository state is
# intact and consumable by a real TUF client. It performs five checks:
#
#   1. Fetch timestamp.json and parse signed.version.
#   2. Drive tuf-ngclient (the python-tuf reference client) through a
#      full refresh starting from a freshly fetched 1.root.json.
#   3. Download trusted_root.json through the refreshed client and
#      verify the byte stream matches the digest in targets.json.
#   4. Parse trusted_root.json as a Sigstore TrustedRoot and assert that
#      the mediaType, certificateAuthorities, and tlogs are well-formed.
#   5. Initialize cosign (a real Sigstore client, go-tuf under the hood)
#      against the repo, so trusted_root.json is fetched and hash-verified
#      by an independent TUF implementation.
#
# Exit status is 0 on full pass. Non-zero on any check failure, with a
# diagnostic message printed to stderr.
#
# Usage:
#   ./smoke_test.sh                             # tests the default URL
#   ./smoke_test.sh https://tuf.example.com    # tests a custom URL (staging)

set -euo pipefail

BASE_URL="${1:-https://tuf.thomsonreuters.com}"
BASE_URL="${BASE_URL%/}"

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

log() { printf '%s %s\n' "[$(date -u +%H:%M:%SZ)]" "$*" >&2; }
fail() { printf '%s FAIL: %s\n' "[$(date -u +%H:%M:%SZ)]" "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Dependency checks
# ---------------------------------------------------------------------------

for cmd in curl jq python3 cosign; do
    command -v "$cmd" >/dev/null 2>&1 || fail "required dependency not found: $cmd"
done

python3 - <<'PY' || fail "python-tuf (tuf.ngclient) is not installed. Run: pip install tuf."
import importlib
importlib.import_module("tuf.ngclient")
PY

# ---------------------------------------------------------------------------
# Check 1 — fetch timestamp.json and parse
# ---------------------------------------------------------------------------

log "==> [1/5] Fetch timestamp.json from $BASE_URL"

curl -fsSL "${BASE_URL}/timestamp.json" -o "$WORKDIR/timestamp.json" \
    || fail "could not GET $BASE_URL/timestamp.json"

TS_VERSION="$(jq -r .signed.version "$WORKDIR/timestamp.json")"
TS_EXPIRES="$(jq -r .signed.expires "$WORKDIR/timestamp.json")"
log "    timestamp.json version=$TS_VERSION expires=$TS_EXPIRES"

# ---------------------------------------------------------------------------
# Check 2 — drive tuf-ngclient through a full refresh
# ---------------------------------------------------------------------------

log "==> [2/5] Drive tuf-ngclient through a full refresh"

curl -fsSL "${BASE_URL}/1.root.json" -o "$WORKDIR/root.json" \
    || fail "could not GET $BASE_URL/1.root.json (initial root)"

mkdir -p "$WORKDIR/state" "$WORKDIR/downloads"

python3 - "$BASE_URL" "$WORKDIR" <<'PY' \
    || fail "tuf-ngclient refresh failed. See traceback above."
import json
import sys
from pathlib import Path
from tuf.ngclient import Updater

base_url = sys.argv[1].rstrip("/")
workdir = Path(sys.argv[2])

updater = Updater(
    metadata_dir=str(workdir / "state"),
    metadata_base_url=base_url + "/",
    target_base_url=base_url + "/targets/",
    target_dir=str(workdir / "downloads"),
    bootstrap=(workdir / "root.json").read_bytes(),
)
updater.refresh()
root_version = json.loads((workdir / "state" / "root.json").read_text())["signed"]["version"]
print(f"    Refresh OK. Trusted root version: {root_version}.")
PY

# ---------------------------------------------------------------------------
# Check 3 — download trusted_root.json through the refreshed client
# ---------------------------------------------------------------------------

log "==> [3/5] Download trusted_root.json by digest"

python3 - "$BASE_URL" "$WORKDIR" <<'PY' \
    || fail "trusted_root.json fetch failed. See traceback above."
import sys
from pathlib import Path
from tuf.ngclient import Updater

base_url = sys.argv[1].rstrip("/")
workdir = Path(sys.argv[2])

updater = Updater(
    metadata_dir=str(workdir / "state"),
    metadata_base_url=base_url + "/",
    target_base_url=base_url + "/targets/",
    target_dir=str(workdir / "downloads"),
    bootstrap=(workdir / "root.json").read_bytes(),
)
updater.refresh()
info = updater.get_targetinfo("trusted_root.json")
if info is None:
    raise SystemExit("trusted_root.json not present in targets.json")

local_path = updater.find_cached_target(info) or updater.download_target(info)
print(f"    downloaded trusted_root.json ({info.length} bytes) to {local_path}")
PY

# ---------------------------------------------------------------------------
# Check 4 — parse trusted_root.json as a Sigstore TrustedRoot
# ---------------------------------------------------------------------------

log "==> [4/5] Parse trusted_root.json structure"

TRUSTED_ROOT="$WORKDIR/downloads/trusted_root.json"
if [[ ! -f "$TRUSTED_ROOT" ]]; then
    # tuf-ngclient may write under a hash-prefixed filename. Find it.
    TRUSTED_ROOT="$(find "$WORKDIR/downloads" -name '*trusted_root.json' | head -n1)"
fi
[[ -n "$TRUSTED_ROOT" && -f "$TRUSTED_ROOT" ]] \
    || fail "trusted_root.json not found in downloads directory"

python3 - "$TRUSTED_ROOT" <<'PY' || fail "trusted_root.json failed structural validation"
import json
import sys
from pathlib import Path

doc = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))

media = doc.get("mediaType", "")
if not media.startswith("application/vnd.dev.sigstore.trustedroot+json"):
    raise SystemExit(f"unexpected mediaType: {media!r}")

cas = doc.get("certificateAuthorities") or []
tlogs = doc.get("tlogs") or []
ctlogs = doc.get("ctlogs") or []
tsas = doc.get("timestampAuthorities") or []

if not cas:
    raise SystemExit("certificateAuthorities is empty")
if not tlogs:
    raise SystemExit("tlogs is empty")

for ca in cas:
    if not ca.get("certChain", {}).get("certificates"):
        raise SystemExit(f"CA entry has no certificates: {ca!r}")
for tlog in tlogs:
    if "rawBytes" not in tlog.get("publicKey", {}):
        raise SystemExit(f"tlog entry has no publicKey.rawBytes: {tlog!r}")
    if "keyId" not in tlog.get("logId", {}):
        raise SystemExit(f"tlog entry has no logId.keyId: {tlog!r}")

print(
    f"    structure OK: {len(cas)} CA(s), {len(tlogs)} tlog(s), "
    f"{len(ctlogs)} ctlog(s), {len(tsas)} tsa(s)"
)
PY

# ---------------------------------------------------------------------------
# Check 5 — initialize cosign (a real Sigstore client) against the repo
# ---------------------------------------------------------------------------

log "==> [5/5] Initialize cosign against the published trust root"

COSIGN_HOME="$WORKDIR/cosign-home"
mkdir -p "$COSIGN_HOME"

HOME="$COSIGN_HOME" cosign initialize \
    --mirror "$BASE_URL" \
    --root "$WORKDIR/root.json" \
    || fail "cosign initialize failed against $BASE_URL"

COSIGN_TRUSTED_ROOT="$(find "$COSIGN_HOME/.sigstore/root" -name 'trusted_root.json' | head -n1)"
[[ -n "$COSIGN_TRUSTED_ROOT" && -s "$COSIGN_TRUSTED_ROOT" ]] \
    || fail "cosign did not materialize trusted_root.json in its TUF cache"

log "    cosign initialized OK. trusted_root.json fetched and hash-verified by go-tuf."

log "==> All checks passed."
exit 0
