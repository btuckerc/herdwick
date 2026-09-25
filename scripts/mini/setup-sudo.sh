#!/bin/bash
# One-time Mac Mini build-host setup that needs an admin password.
# Run from any terminal:  ssh -t admin@macmini 'sudo bash ~/herdwick-setup/setup-sudo.sh'
# 1. Selects Xcode 27 on /Volumes/E0.
# 2. Installs a one-shot boot job that accepts the Xcode license and runs first launch
#    after the OS update (Xcode 27 needs macOS >= 26.6). It removes itself on success.
# 3. Installs the macOS 26.7 update and restarts. Apple Silicon asks for the admin
#    password a second time here (volume owner authorization).
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "run with sudo" >&2; exit 1; }

XCODE=/Volumes/E0/Developer/Xcode-27.0.app
UPDATE="macOS Tahoe 26.7-25G229"
LABEL=dev.btuckerc.herdwick-firstboot
[ -d "$XCODE" ] || { echo "missing $XCODE" >&2; exit 1; }

xcode-select -s "$XCODE/Contents/Developer"

install -d -m 755 -o root -g wheel /usr/local/libexec
cat >/usr/local/libexec/herdwick-firstboot.sh <<EOF
#!/bin/bash
exec >>/var/log/herdwick-firstboot.log 2>&1
echo "== \$(date) macOS \$(sw_vers -productVersion)"
for _ in \$(seq 1 120); do [ -d "$XCODE" ] && break; sleep 5; done
export DEVELOPER_DIR="$XCODE/Contents/Developer"
if xcodebuild -license accept && xcodebuild -runFirstLaunch; then
  echo FIRSTBOOT_OK
  rm -f /Library/LaunchDaemons/$LABEL.plist /usr/local/libexec/herdwick-firstboot.sh
  launchctl bootout system/$LABEL
fi
EOF
chown root:wheel /usr/local/libexec/herdwick-firstboot.sh
chmod 755 /usr/local/libexec/herdwick-firstboot.sh

cat >/Library/LaunchDaemons/$LABEL.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>/bin/bash</string><string>/usr/local/libexec/herdwick-firstboot.sh</string></array>
  <key>RunAtLoad</key><true/>
</dict></plist>
EOF
chown root:wheel /Library/LaunchDaemons/$LABEL.plist
chmod 644 /Library/LaunchDaemons/$LABEL.plist

echo "Installing $UPDATE; the Mini restarts when it finishes."
softwareupdate --install "$UPDATE" --agree-to-license --restart
