#!/bin/bash
# Uninstall VoltBar:  sudo "/Library/Application Support/VoltBar/uninstall.sh"
# (VoltageShift.kext is not touched.)
set -uo pipefail
if [[ $EUID -ne 0 ]]; then echo "Run with sudo" >&2; exit 1; fi

SUPPORT="/Library/Application Support/VoltBar"

/usr/local/bin/voltbarctl reset 2>/dev/null || true
pkill -x VoltBar 2>/dev/null || true
launchctl bootout system/com.voltbar.daemon 2>/dev/null || true
kmutil unload -b com.voltbar.msr 2>/dev/null || true
rm -f /Library/LaunchDaemons/com.voltbar.daemon.plist
rm -f /Library/PrivilegedHelperTools/com.voltbar.daemon
rm -f /usr/local/bin/voltbarctl
rm -f /var/run/com.voltbar.daemon.sock
rm -rf /Applications/VoltBar.app

# Restore VoltageShift's launch daemon if the installer disabled it.
if [[ -f "$SUPPORT/com.sicreative.VoltageShift.plist.disabled" ]]; then
    read -r -p "Restore VoltageShift's launch daemon (com.sicreative.VoltageShift)? [y/N] " ans
    if [[ "$ans" =~ ^[Yy]$ ]]; then
        mv "$SUPPORT/com.sicreative.VoltageShift.plist.disabled" /Library/LaunchDaemons/com.sicreative.VoltageShift.plist
        chown root:wheel /Library/LaunchDaemons/com.sicreative.VoltageShift.plist
        launchctl bootstrap system /Library/LaunchDaemons/com.sicreative.VoltageShift.plist 2>/dev/null || true
        echo "VoltageShift launch daemon restored."
    fi
fi

rm -rf "$SUPPORT"
pkgutil --forget com.voltbar.pkg >/dev/null 2>&1 || true
echo "VoltBar removed. Voltages were reset to factory values."
echo "VoltageShift.kext (if any) was not touched."
