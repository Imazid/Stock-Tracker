#!/bin/sh
set -eu

source_plist="$SRCROOT/Stock Tracker/Config/Secrets.plist"
bundle_plist="$SCRIPT_OUTPUT_FILE_0"

if [ "${CONFIGURATION:-}" = Debug ] && [ -f "$source_plist" ]; then
    /usr/bin/plutil -lint "$source_plist" >/dev/null
    /bin/cp "$source_plist" "$bundle_plist"
    exit
fi

/usr/bin/plutil -create xml1 "$bundle_plist"
if [ -f "$source_plist" ]; then
    /usr/bin/plutil -lint "$source_plist" >/dev/null
    for key in SupabaseURL SupabaseAnonKey; do
        if value=$(/usr/bin/plutil -extract "$key" raw -expect string "$source_plist" 2>/dev/null); then
            /usr/bin/plutil -insert "$key" -string "$value" "$bundle_plist"
        fi
    done
fi
