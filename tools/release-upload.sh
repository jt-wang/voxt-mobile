#!/bin/bash
# Uploads a release only if release-gate.py check passes for it.
#   tools/release-upload.sh (--remote URL | --local REPO --export DIR) [--require-remote] ARTIFACT... -- UPLOAD COMMAND...
# Everything before -- goes to `release-gate.py check`; the command after -- runs only when it passes,
# for example: ... VoxtMobile.ipa -- xcrun altool --upload-package VoxtMobile.ipa ...
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
check=()
while (( $# )) && [[ $1 != -- ]]; do check+=("$1"); shift; done
[[ ${1:-} == -- ]] || { echo "release-upload: missing -- before the upload command" >&2; exit 2; }
shift
(( $# )) || { echo "release-upload: no upload command after --" >&2; exit 2; }
python3 -I "$here/release-gate.py" check "${check[@]}" || { echo "release-upload: not uploaded" >&2; exit 1; }
exec "$@"
