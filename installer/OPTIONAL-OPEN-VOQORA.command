#!/bin/zsh
set -eu

APP="/Applications/Voqora.app"

if [[ ! -d "$APP" ]]; then
  echo "Voqora was not found in Applications. Drag Voqora.app to Applications first."
  read "?Press Return to close this window."
  exit 1
fi

echo "Clearing the downloaded-file quarantine marker from this installed Voqora app only…"
/usr/bin/xattr -dr com.apple.quarantine "$APP"
/usr/bin/open "$APP"
echo "Opened Voqora from Applications."
read "?Press Return to close this window."
