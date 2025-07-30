#!/bin/bash

INPUT_DIR="$1"
OUTPUT_DIR="$2"
MONKEY_SEED=12345
#EMULATOR_COMMAND="emulator -avd Android7_API24 -no-window -no-audio -memory 2048 -wipe-data -no-snapshot-load -no-snapshot-save &"
EMULATOR_COMMAND="emulator -avd Android11_API30_Play -no-window -no-audio -memory 2048 -wipe-data -no-snapshot-load -no-snapshot-save &"
if [ -z "$INPUT_DIR" ] || [ -z "$OUTPUT_DIR" ]; then
  echo "Usage: $0 <input_apk_dir> <output_apk_dir>"
  exit 1
fi

mkdir -p "$OUTPUT_DIR"
total_apps=$(ls "$INPUT_DIR"/*.apk 2>/dev/null | wc -l)
initially_healthy=0
apk_counter=0

# Start emulator if not already running
wait_for_boot() {
  echo "Waiting for emulator to boot..."
  adb wait-for-device
  until [[ "$(adb shell getprop sys.boot_completed | tr -d '\r')" == "1" ]]; do
    sleep 5
  done
  echo "Boot completed."
}

start_emulator() {
  if ! adb shell getprop sys.boot_completed | grep -q "1"; then
    echo "Starting emulator..."
    eval "$EMULATOR_COMMAND"
    wait_for_boot
  else
    echo "Emulator already running."
  fi
}

restart_emulator() {
  echo "Restarting emulator..."
  adb emu kill
  sleep 10
  start_emulator
}

start_emulator
adb shell mkdir -p /sdcard/Download >/dev/null 2>&1

for apk in "$INPUT_DIR"/*.apk; do
  ((apk_counter++))
  echo -e "\n[$apk_counter/$total_apps] Testing $(basename "$apk")"

  # Restart emulator every 25 APKs
  if (( apk_counter % 25 == 0 )); then
    restart_emulator
  fi

  # Clear previous logs and installs
  adb logcat -c
  pkg=$(aapt dump badging "$apk" | awk -F"'" '/package: name=/{print $2}')
  [[ -z "$pkg" ]] && echo "Could not extract package name — skipping" && continue
  adb uninstall "$pkg" >/dev/null 2>&1 || true

  # Install APK
  if ! timeout 60s adb install "$apk" >/dev/null 2>&1; then
    echo "❌ Install failed or timed out"
    continue
  fi

  # New with timeout
  if ! timeout 30s adb shell monkey -p "$pkg" --throttle 100 -s "$MONKEY_SEED" \
      --ignore-crashes --ignore-timeouts --monitor-native-crashes 200 >/dev/null 2>&1; then
    echo "❌ Monkey test timed out or failed"
    adb uninstall "$pkg" >/dev/null 2>&1 || true
    continue
  fi

  if adb logcat -d | grep -q "FATAL EXCEPTION\|VerifyError"; then
    echo "❌ Crashed during Monkey test"
  else
    echo "✅ Passed health check"
    ((initially_healthy++))
    cp "$apk" "$OUTPUT_DIR/"
  fi

  # Clean up
  adb uninstall "$pkg" >/dev/null 2>&1 || true
  adb logcat -c
done

adb emu kill || true

# Summary
echo
echo "==== EXPERIMENT SUMMARY ===="
echo "Total Apps: $total_apps"
echo "Initially Healthy Apps: $initially_healthy"

