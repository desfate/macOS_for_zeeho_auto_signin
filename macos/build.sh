#!/bin/zsh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/macos/ZeehoSignin/ZeehoSigninApp.swift"
PATHS="$ROOT/macos/ZeehoSignin/Paths.swift"
APP_DIR="${HOME}/Applications/ZeehoSignin.app"
MACOS_DIR="$APP_DIR/Contents/MacOS"
RES_DIR="$APP_DIR/Contents/Resources"
mkdir -p "$MACOS_DIR" "$RES_DIR"

if [[ -x /Library/Frameworks/Python.framework/Versions/3.13/bin/python3 ]]; then
  PYTHON_BIN="/Library/Frameworks/Python.framework/Versions/3.13/bin/python3"
else
  PYTHON_BIN="$(command -v python3)"
fi

python3 - "$PATHS" "$PYTHON_BIN" "$ROOT/scripts/zeeho_signin.py" <<'PY'
import json, sys
from pathlib import Path
out, py, script = sys.argv[1], sys.argv[2], sys.argv[3]
Path(out).write_text(
    "enum ZeehoPaths {\n"
    f"    static let pythonBin = {json.dumps(py)}\n"
    f"    static let pythonScript = {json.dumps(script)}\n"
    "}\n",
    encoding="utf-8",
)
PY

swiftc -parse-as-library -O \
  -target arm64-apple-macosx14.0 \
  -sdk "$(xcrun --show-sdk-path --sdk macosx)" \
  -framework SwiftUI -framework AppKit -framework Combine \
  -o "$MACOS_DIR/ZeehoSignin" \
  "$SRC" "$PATHS"
cp "$ROOT/macos/ZeehoSignin/Info.plist" "$APP_DIR/Contents/Info.plist"
printf 'APPL????' > "$APP_DIR/Contents/PkgInfo"
cp "$ROOT/macos/ZeehoSignin/Assets/AppIcon.icns" "$RES_DIR/AppIcon.icns"
sips -z 128 128 "$ROOT/macos/ZeehoSignin/Assets/zeeho-mark-1024.png" --out "$RES_DIR/zeeho-mark.png" >/dev/null
cp "$ROOT/macos/ZeehoSignin/Assets/zeeho-menu.png" "$RES_DIR/zeeho-menu.png"
chmod +x "$MACOS_DIR/ZeehoSignin"
codesign --force --deep -s - "$APP_DIR" 2>/dev/null || true

# 必须在 codesign 之后盖图标，否则签名会清掉 Finder/启动台看到的自定义图标
ICON_APP="$APP_DIR" ICON_ICNS="$RES_DIR/AppIcon.icns" swift -e '
import AppKit
let env = ProcessInfo.processInfo.environment
let app = env["ICON_APP"]!
let icns = env["ICON_ICNS"]!
guard let img = NSImage(contentsOfFile: icns) else { fatalError("no icns") }
_ = NSWorkspace.shared.setIcon(img, forFile: app, options: [])
'

/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP_DIR" >/dev/null 2>&1 || true
echo "built $APP_DIR"
