#!/bin/bash
# Build a local camera preview with ad-hoc signing; no Apple account or extension.
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$PWD/.venv/bin:$PATH"
models="${LOCKED_GAZE_MODELS_PATH:-/Applications/Locked Gaze.app/Contents/Resources/Models}"
app="$PWD/build/Preview/Locked Gaze Preview.app"
[[ -f build/deps/opencv/lib/libopencv_calib3d.a ]] || bash scripts/build-opencv.sh
# Stage in a separate directory so preview builds do not modify app build resources.
for key in face landmarks encoder decoder; do
    [[ -d "$models/$key.mlmodelc" && -f "$models/$key.json" ]] || {
        echo "Missing $key model in $models. Set LOCKED_GAZE_MODELS_PATH to compatible compiled models." >&2
        exit 1
    }
done
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" build/Preview
xcrun clang++ -std=c++17 -fobjc-arc -fmodules -arch arm64 -mmacosx-version-min=14.0 -O2 \
    -I Native/include -I build/deps/opencv/include/opencv4 \
    -c Native/LGFramePipeline.mm -o build/Preview/LGFramePipeline.o
xcrun swiftc -swift-version 5 -O -target arm64-apple-macos14.0 \
    -import-objc-header Native/include/LGFramePipeline.h \
    Sources/Core/*.swift Sources/Shared/*.swift Sources/PublisherIPC/*.swift \
    Sources/App/CameraSession.swift Sources/App/CameraPublisherClient.swift Sources/Preview/main.swift \
    build/Preview/LGFramePipeline.o \
    -L build/deps/opencv/lib -L build/deps/opencv/lib/opencv4/3rdparty \
    -lopencv_calib3d -lopencv_features2d -lopencv_flann -lopencv_imgproc -lopencv_core -ltegra_hal \
    -lc++ -lz -framework Foundation -framework AppKit -framework AVFoundation \
    -framework CoreVideo -framework CoreImage -framework CoreML -framework Metal -framework Accelerate \
    -o "$app/Contents/MacOS/LockedGazePreview"
python3 - "$app" <<'PY'
import plistlib, sys
from pathlib import Path
app = Path(sys.argv[1])
info = dict(CFBundleIdentifier='local.lockedgaze.preview', CFBundleExecutable='LockedGazePreview',
    CFBundleName='Locked Gaze Preview', CFBundlePackageType='APPL', CFBundleVersion='1',
    CFBundleShortVersionString='1.0', LSMinimumSystemVersion='14.0', NSHighResolutionCapable=True,
    NSCameraUsageDescription='Show a local live preview of eye-contact correction. No video is recorded or uploaded.',
    NSCameraUseContinuityCameraDeviceType=True)
(app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
PY
# ditto replaces model files; clean only this generated preview's model directory.
rm -rf "$app/Contents/Resources/Models"
ditto "$models" "$app/Contents/Resources/Models"
codesign --force --sign - --identifier local.lockedgaze.preview "$app"
codesign --verify --strict "$app"
echo "Built: $app"
echo 'Launch: open "build/Preview/Locked Gaze Preview.app"'
