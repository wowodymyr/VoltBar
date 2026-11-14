#!/bin/bash
# Builds VoltBar and packages it into build/VoltBar-<version>.pkg.
# Requires Xcode or the Command Line Tools (xcode-select --install). No sudo needed.
set -euo pipefail
cd "$(dirname "$0")"

# If the selected Xcode can't be used (e.g. license not accepted), fall back to the Command Line Tools.
if ! xcrun --find swiftc >/dev/null 2>&1 && [[ -x /Library/Developer/CommandLineTools/usr/bin/swiftc ]]; then
    export DEVELOPER_DIR=/Library/Developer/CommandLineTools
    echo "(xcrun unavailable with the selected Xcode — using Command Line Tools)"
fi
if ! xcrun --find swiftc >/dev/null 2>&1; then
    echo "swiftc not found. Install the Command Line Tools: xcode-select --install" >&2
    exit 1
fi

VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)
SWIFTC=(xcrun swiftc -O -target x86_64-apple-macos12.0)
APP=build/VoltBar.app
ROOT=build/pkgroot
PKG="build/VoltBar-$VERSION.pkg"

rm -rf build
mkdir -p build "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "→ daemon"
"${SWIFTC[@]}" -o build/voltbard Shared/Protocol.swift Daemon/*.swift

echo "→ CLI"
"${SWIFTC[@]}" -o build/voltbarctl Shared/Protocol.swift CLI/main.swift

echo "→ app"
"${SWIFTC[@]}" -parse-as-library -o "$APP/Contents/MacOS/VoltBar" Shared/Protocol.swift App/*.swift
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [[ ! -f Resources/AppIcon.icns ]]; then
    echo "→ icon"
    xcrun swift Tools/make-icon.swift Resources/AppIcon.icns
fi
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"
# Files end up owned by root after install — make sure everyone can read them.
chmod -R u+rwX,go+rX-w "$APP"

echo "→ kext (VoltBarMSR)"
Kext/build-kext.sh build >/dev/null 2>/tmp/voltbar-kext-$$.log || { cat /tmp/voltbar-kext-$$.log >&2; exit 1; }
grep -v "was built for newer macOS version" /tmp/voltbar-kext-$$.log >&2 || true
rm -f /tmp/voltbar-kext-$$.log

echo "→ codesign (ad-hoc)"
codesign --force --sign - build/voltbard
codesign --force --sign - build/voltbarctl
codesign --force --deep --sign - "$APP"

echo "→ package payload"
mkdir -p "$ROOT/Applications" "$ROOT/Library/PrivilegedHelperTools" "$ROOT/Library/LaunchDaemons" \
         "$ROOT/usr/local/bin" "$ROOT/Library/Application Support/VoltBar"
cp -R "$APP" "$ROOT/Applications/"
install -m 755 build/voltbard "$ROOT/Library/PrivilegedHelperTools/com.voltbar.daemon"
install -m 644 Resources/com.voltbar.daemon.plist "$ROOT/Library/LaunchDaemons/com.voltbar.daemon.plist"
install -m 755 build/voltbarctl "$ROOT/usr/local/bin/voltbarctl"
install -m 755 uninstall.sh "$ROOT/Library/Application Support/VoltBar/uninstall.sh"
cp -R build/VoltBarMSR.kext "$ROOT/Library/Application Support/VoltBar/VoltBarMSR.kext"
chmod 755 Installer/scripts/preinstall Installer/scripts/postinstall

# Install the app exactly into /Applications (don't let Installer "relocate" it to another copy on disk).
pkgbuild --analyze --root "$ROOT" build/component.plist >/dev/null
n=0
while /usr/libexec/PlistBuddy -c "Print :$n:RootRelativeBundlePath" build/component.plist >/dev/null 2>&1; do
    for key in BundleIsRelocatable BundleIsVersionChecked; do
        /usr/libexec/PlistBuddy -c "Set :$n:$key false" build/component.plist 2>/dev/null || \
            /usr/libexec/PlistBuddy -c "Add :$n:$key bool false" build/component.plist
    done
    n=$((n + 1))
done

pkgbuild --root "$ROOT" \
         --component-plist build/component.plist \
         --scripts Installer/scripts \
         --identifier com.voltbar.pkg \
         --version "$VERSION" \
         --ownership recommended \
         --install-location / \
         build/VoltBar-component.pkg >/dev/null

sed "s/__VERSION__/$VERSION/" Installer/distribution.xml > build/distribution.xml
productbuild --distribution build/distribution.xml \
             --resources Installer/resources \
             --package-path build \
             "$PKG" >/dev/null

rm -f build/VoltBar-component.pkg build/component.plist build/distribution.xml

echo "Done: $PKG"
