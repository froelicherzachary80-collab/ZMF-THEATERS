#!/usr/bin/env bash
# Downloads Apple's Core ML build of Depth Anything V2 (small, Float16) used by
# ZMF DepthCinema AI for 2D → 3D conversion. Xcode compiles it into the app.
set -euo pipefail
DEST="$(cd "$(dirname "$0")/.." && pwd)/ZMFTheaters/Models"
mkdir -p "$DEST"
if [ -f "$DEST/DepthAnythingV2SmallF16.mlpackage/Manifest.json" ]; then
  echo "Depth model already present"; exit 0
fi
VENV="${TMPDIR:-/tmp}/zmf-hf-venv"
python3 -m venv "$VENV"
"$VENV/bin/pip" install --quiet huggingface_hub
STAGE="${TMPDIR:-/tmp}/zmf-depth-model"
rm -rf "$STAGE"; mkdir -p "$STAGE"
for attempt in 1 2 3; do
  if "$VENV/bin/python" - "$STAGE" <<'PY'
import sys
from huggingface_hub import snapshot_download
snapshot_download("apple/coreml-depth-anything-v2-small",
                  allow_patterns=["DepthAnythingV2SmallF16.mlpackage/*"],
                  local_dir=sys.argv[1])
PY
  then break; fi
  echo "Download attempt $attempt failed; retrying"; sleep $((attempt * 5))
done
# Copy only the model package; the downloader's .cache metadata must stay out of the Xcode folder.
rm -rf "$DEST/DepthAnythingV2SmallF16.mlpackage" "$DEST/.cache"
cp -R "$STAGE/DepthAnythingV2SmallF16.mlpackage" "$DEST/"
test -f "$DEST/DepthAnythingV2SmallF16.mlpackage/Manifest.json"
du -sh "$DEST/DepthAnythingV2SmallF16.mlpackage"
