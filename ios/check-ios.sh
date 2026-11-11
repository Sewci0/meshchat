#!/bin/sh
# Type-checks the iPhone-only code without Xcode: the screens' UIKit parts and the app target (entry
# point, notifications, the MapLibre map), compiled as Mac Catalyst against the iOS frameworks that ship
# inside the macOS SDK. The camera scanner (VisionKit's DataScanner) isn't on Catalyst, so it's the one
# part this can't check. With Xcode installed, build the MeshChat scheme instead.
set -eu
cd "$(dirname "$0")"
SDK=$(xcrun --show-sdk-path)
IOSSUPPORT="$SDK/System/iOSSupport"
T=arm64-apple-ios17.0-macabi
OUT=.build/catalyst

echo "· screens (MeshChatUI) as Mac Catalyst"
swift build --scratch-path "$OUT" --triple $T --target MeshChatUI \
  -Xswiftc -target -Xswiftc $T -Xcc -target -Xcc $T \
  -Xswiftc -Fsystem -Xswiftc "$IOSSUPPORT/System/Library/Frameworks" \
  -Xswiftc -I -Xswiftc "$IOSSUPPORT/usr/lib/swift" \
  -Xcc -iframework -Xcc "$IOSSUPPORT/System/Library/Frameworks"

# MapLibre's headers, at the version project.yml asks for, checked against the distribution's checksum
V=$(sed -n 's/^ *from: *\([0-9.]*\).*/\1/p' project.yml | head -1)
ML=.build/maplibre-$V
if [ ! -d "$ML/MapLibre.framework" ]; then
  echo "· MapLibre $V headers"
  mkdir -p "$ML"
  SUM=$(curl -fsSL "https://raw.githubusercontent.com/maplibre/maplibre-gl-native-distribution/$V/Package.swift" | sed -n 's/.*checksum: "\([0-9a-f]*\)".*/\1/p')
  curl -fsSL -o "$ML/ml.zip" "https://github.com/maplibre/maplibre-native/releases/download/ios-v$V/MapLibre.dynamic.xcframework.zip"
  echo "$SUM  $ML/ml.zip" | shasum -a 256 -c -
  unzip -q "$ML/ml.zip" -d "$ML/x"
  cp -R "$ML/x/MapLibre.xcframework/ios-arm64/MapLibre.framework" "$ML/"
  # OpenGL ES isn't on Catalyst: one deprecated property names its type
  sed -i '' 's/^@property (nonatomic, readonly) EAGLContext \*context;/@property (nonatomic, readonly) id context;/' \
    "$ML/MapLibre.framework/Headers/MLNCustomStyleLayer.h"
  rm -rf "$ML/x" "$ML/ml.zip"
fi

echo "· app target (App/)"
MAP=$(find "$OUT/checkouts" -path "*GRDBSQLite*" -name module.modulemap | head -1)
xcrun swiftc -typecheck -swift-version 6 -parse-as-library -target $T -sdk "$SDK" \
  -Fsystem "$IOSSUPPORT/System/Library/Frameworks" -I "$IOSSUPPORT/usr/lib/swift" \
  -Xcc -iframework -Xcc "$IOSSUPPORT/System/Library/Frameworks" -Xcc -fmodule-map-file="$MAP" \
  -I "$OUT/arm64-apple-ios-macabi/debug/Modules" -F "$ML" App/*.swift
echo "✔ iOS code type-checks"
