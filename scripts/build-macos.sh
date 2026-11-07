#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="${DIST_DIR:-$PROJECT_DIR/dist/release-0.4.6}"
FINAL_APP_DIR="$DIST_DIR/PURE Neg.app"
BUILD_DIR="$PROJECT_DIR/.build/macos"
ICON_SOURCE="$PROJECT_DIR/assets/PURENeg.png"
WORDMARK_SOURCE="$PROJECT_DIR/assets/PURENeg-wordmark.png"
LAUNCH_SOURCE="$PROJECT_DIR/assets/PURENeg-launch.png"
SUPPORT_SOURCE="$PROJECT_DIR/assets/SupportAlipay.jpg"
NODE_BINARY="${NODE_BINARY:-$(command -v node || true)}"
NODE_LICENSE="${NODE_LICENSE:-}"
LAUNCHER="$PROJECT_DIR/scripts/打开 PURE Neg.command"
package_mode=
case "${APP_ONLY:-0}:${PACKAGE_BETA:-0}:${PACKAGE_RELEASE:-0}" in
  0:0:0|1:0:0) ;;
  0:1:0) package_mode=beta ;;
  0:0:1) package_mode=release ;;
  *) echo "Choose at most one of APP_ONLY, PACKAGE_BETA and PACKAGE_RELEASE." >&2; exit 1 ;;
esac

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This script builds the macOS desktop app and must run on macOS." >&2
  exit 1
fi
if [[ -z "$NODE_BINARY" || ! -x "$NODE_BINARY" ]]; then
  echo "Set NODE_BINARY to an executable Node.js 22+ binary." >&2
  exit 1
fi
if [[ ! -f "$PROJECT_DIR/src/cli.cjs" || ! -f "$PROJECT_DIR/vendor/film-dust/engine/pipeline.js" ]]; then
  echo "Missing CLI or vendored film-dust engine. Prepare the source tree before packaging." >&2
  exit 1
fi
if [[ ! -f "$ICON_SOURCE" || ! -f "$WORDMARK_SOURCE" || ! -f "$LAUNCH_SOURCE" ]]; then
  echo "Missing PURE Neg icon, wordmark or launch artwork in $PROJECT_DIR/assets" >&2
  exit 1
fi
if [[ ! -f "$SUPPORT_SOURCE" ]]; then
  echo "Missing the PURE Neg support artwork." >&2
  exit 1
fi
if [[ -n "$package_mode" && ( "${ADHOC_SIGN:-1}" != "1" || ! -x "$LAUNCHER" ) ]]; then
  echo "The distribution package requires local ad-hoc signing and an executable launcher." >&2
  exit 1
fi

NODE_MAJOR="$("$NODE_BINARY" -p 'Number(process.versions.node.split(".")[0])')"
if [[ "$NODE_MAJOR" -lt 22 ]]; then
  echo "Node.js 22 or newer is required." >&2
  exit 1
fi
NODE_VERSION="$("$NODE_BINARY" --version)"
if [[ -z "$NODE_LICENSE" ]]; then
  NODE_HOME="$(cd "$(dirname "$NODE_BINARY")/.." && pwd)"
  for candidate in "$PROJECT_DIR/licenses/node-$NODE_VERSION-LICENSE" "$NODE_HOME/LICENSE"; do
    if [[ -f "$candidate" ]]; then
      NODE_LICENSE="$candidate"
      break
    fi
  done
fi
if [[ -z "$NODE_LICENSE" || ! -f "$NODE_LICENSE" ]]; then
  echo "Set NODE_LICENSE to the complete LICENSE file for $NODE_VERSION, including dependency notices." >&2
  exit 1
fi

mkdir -p "$BUILD_DIR" "$DIST_DIR"
STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/PURENeg-bundle.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT
APP_DIR="$STAGING_DIR/PURE Neg.app"
ARCH="${MACOS_ARCH:-$(uname -m)}"
if [[ "$ARCH" != "arm64" && "$ARCH" != "x86_64" ]]; then
  echo "Unsupported architecture: $ARCH" >&2
  exit 1
fi
NODE_ARCH="$("$NODE_BINARY" -p 'process.arch')"
if [[ ( "$ARCH" == "arm64" && "$NODE_ARCH" != "arm64" ) || ( "$ARCH" == "x86_64" && "$NODE_ARCH" != "x64" ) ]]; then
  echo "Node architecture ($NODE_ARCH) does not match the application target ($ARCH)." >&2
  exit 1
fi

swiftc -parse-as-library -swift-version 5 -O -target "$ARCH-apple-macos14.0" \
  -framework AppKit -framework UniformTypeIdentifiers \
  "$PROJECT_DIR/macos/PURENeg.swift" "$PROJECT_DIR/macos/PreviewCanvas.swift" \
  "$PROJECT_DIR/macos/ReviewLoadingView.swift" \
  "$PROJECT_DIR/macos/BatchLightTable.swift" "$PROJECT_DIR/macos/BatchReviewSidebar.swift" \
  "$PROJECT_DIR/macos/PhotoshopImport.swift" "$PROJECT_DIR/macos/SupportWindows.swift" \
  "$PROJECT_DIR/macos/SettingsWindow.swift" "$PROJECT_DIR/macos/Localization.swift" -o "$BUILD_DIR/PURENeg"
swiftc -parse-as-library -swift-version 5 -O -target "$ARCH-apple-macos14.0" \
  -framework ImageIO -framework CoreGraphics -framework UniformTypeIdentifiers \
  "$PROJECT_DIR/macos/ImageCodec.swift" -o "$BUILD_DIR/image-codec"

mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources/runtime"
cp -X "$BUILD_DIR/PURENeg" "$APP_DIR/Contents/MacOS/PURENeg"
cp -X "$NODE_BINARY" "$APP_DIR/Contents/Resources/runtime/node"
cp -X "$BUILD_DIR/image-codec" "$APP_DIR/Contents/Resources/runtime/image-codec"
cp -X "$NODE_LICENSE" "$APP_DIR/Contents/Resources/runtime/LICENSE"
mkdir -p "$APP_DIR/Contents/Resources/ThirdPartyLicenses"
cp -X "$PROJECT_DIR/licenses/torchvision-LICENSE" "$APP_DIR/Contents/Resources/ThirdPartyLicenses/"
chmod 755 "$APP_DIR/Contents/MacOS/PURENeg" "$APP_DIR/Contents/Resources/runtime/node" "$APP_DIR/Contents/Resources/runtime/image-codec"
ditto --norsrc --noextattr --noqtn "$PROJECT_DIR/src" "$APP_DIR/Contents/Resources/src"
ditto --norsrc --noextattr --noqtn "$PROJECT_DIR/vendor" "$APP_DIR/Contents/Resources/vendor"
ditto --norsrc --noextattr --noqtn "$PROJECT_DIR/macos/Resources/en.lproj" "$APP_DIR/Contents/Resources/en.lproj"
for document in README.md LICENSE THIRD_PARTY_NOTICES.md VALIDATION.md; do
  if [[ -f "$PROJECT_DIR/$document" ]]; then
    cp -X "$PROJECT_DIR/$document" "$APP_DIR/Contents/Resources/$document"
  fi
done

cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
  <key>CFBundleDisplayName</key><string>PURE Neg</string>
  <key>CFBundleExecutable</key><string>PURENeg</string>
  <!-- Keep the registered identifier for macOS settings and automation permissions. -->
  <key>CFBundleIdentifier</key><string>local.filmdust.photocraft.review</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>PURE Neg</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.4.6</string>
  <key>CFBundleVersion</key><string>18</string>
  <key>CFBundleIconFile</key><string>PURENeg</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSAppleEventsUsageDescription</key><string>PURE Neg 需要读取 Photoshop 当前文档的可见图像，用于在本机生成除尘预览。</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHumanReadableCopyright</key><string>Includes film-dust by Magnus Holmes, MIT license.</string>
</dict></plist>
PLIST

if [[ "${APP_ONLY:-0}" == "1" ]]; then
  /usr/bin/plutil -replace CFBundleIdentifier -string local.filmdust.photocraft.review.validation "$APP_DIR/Contents/Info.plist"
fi

ICONSET="$STAGING_DIR/PURENeg.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$ICON_SOURCE" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  sips -z "$((size * 2))" "$((size * 2))" "$ICON_SOURCE" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP_DIR/Contents/Resources/PURENeg.icns"
cp -X "$ICONSET/icon_512x512.png" "$APP_DIR/Contents/Resources/PURENeg.png"
cp -X "$WORDMARK_SOURCE" "$APP_DIR/Contents/Resources/PURENeg-wordmark.png"
cp -X "$LAUNCH_SOURCE" "$APP_DIR/Contents/Resources/PURENeg-launch.png"
cp -X "$SUPPORT_SOURCE" "$APP_DIR/Contents/Resources/SupportAlipay.jpg"

if [[ "${ADHOC_SIGN:-1}" == "1" ]]; then
  codesign --force --sign - "$APP_DIR/Contents/Resources/runtime/node"
  codesign --force --sign - "$APP_DIR/Contents/Resources/runtime/image-codec"
  for addon in "$APP_DIR/Contents/Resources/vendor/film-dust/native/build/"*.node; do
    [[ -f "$addon" ]] || continue
    codesign --force --sign - "$addon"
  done
  codesign --force --sign - "$APP_DIR"
  codesign --verify --deep --strict "$APP_DIR"
fi

# Sign outside synced/file-provider folders: they can add FinderInfo while
# codesign reads the bundle. The ZIP is the reproducible distribution artifact.
ZIP_PATH="$DIST_DIR/PURE Neg-macos-$ARCH.zip"
if [[ "${APP_ONLY:-0}" != "1" && "$package_mode" != "release" ]]; then
  ditto -c -k --norsrc --keepParent "$APP_DIR" "$ZIP_PATH"
  echo "Archive: $ZIP_PATH"
fi
if [[ -e "$FINAL_APP_DIR" ]]; then
  rm -rf "$FINAL_APP_DIR"
fi
ditto --norsrc --noextattr --noqtn "$APP_DIR" "$FINAL_APP_DIR"

if [[ -n "$package_mode" ]]; then
  app_version="$(/usr/bin/plutil -extract CFBundleShortVersionString raw "$APP_DIR/Contents/Info.plist")"
  if [[ "$package_mode" == "beta" ]]; then
    platform="Intel"
    if [[ "$ARCH" == "arm64" ]]; then platform="Apple Silicon"; fi
    package_dir="$STAGING_DIR/PURE Neg $app_version 内测版"
    package_archive="$DIST_DIR/PURE Neg-内测包-$platform.zip"
  else
    package_dir="$STAGING_DIR/PURE Neg $app_version"
    package_archive="$DIST_DIR/PURE-Neg-$app_version-macos-$ARCH.zip"
  fi
  mkdir "$package_dir"
  ditto --norsrc --noextattr --noqtn "$APP_DIR" "$package_dir/PURE Neg.app"
  install -m 0755 "$LAUNCHER" "$package_dir/打开 PURE Neg.command"
  codesign --verify --deep --strict "$package_dir/PURE Neg.app"
  ditto -c -k --norsrc --keepParent "$package_dir" "$STAGING_DIR/distribution.zip"
  mv -f "$STAGING_DIR/distribution.zip" "$package_archive"
  echo "Distribution archive: $package_archive"
fi

echo "Built: $FINAL_APP_DIR"
echo "Node: $("$NODE_BINARY" --version) ($ARCH)"
echo "Local ad-hoc signing: ${ADHOC_SIGN:-1}. This build has no Apple notarization."
