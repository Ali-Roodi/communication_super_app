#!/bin/bash
# Script to fix telephony package namespace issue
# This script adds the required namespace to the telephony package's build.gradle

TELEPHONY_PATH="$HOME/.pub-cache/hosted/pub.dev/telephony-0.2.0/android/build.gradle"

if [ -f "$TELEPHONY_PATH" ]; then
    if ! grep -q "namespace\s*=" "$TELEPHONY_PATH"; then
        sed -i.bak '/^android {/a\
    namespace = "com.shounakmulay.telephony"
' "$TELEPHONY_PATH"
        echo "Fixed telephony package namespace"
    else
        echo "Telephony package namespace already fixed"
    fi
else
    echo "Telephony package not found. Run 'flutter pub get' first."
fi























