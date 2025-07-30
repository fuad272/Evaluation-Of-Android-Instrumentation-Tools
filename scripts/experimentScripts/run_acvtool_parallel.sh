#!/bin/bash

INPUT_DIR="$1"
OUTPUT_DIR="$2"
EMULATOR_NAME="$3"
EMULATOR_PORT="$4"

CSV_FILE="$OUTPUT_DIR/coverage_results.csv"
LOG_DIR="$OUTPUT_DIR/logs"
MONKEY_SEED=12345
ACV_TIMEOUT=3600
export ANDROID_SERIAL="emulator-${EMULATOR_PORT}"


if [ -z "$INPUT_DIR" ] || [ -z "$OUTPUT_DIR" ] || [ -z "$EMULATOR_NAME" ] || [ -z "$EMULATOR_PORT" ]; then
  echo "Usage: $0 <input_apk_dir> <output_dir> <emulator_name> <emulator_port>"
  exit 1
fi

mkdir -p "$OUTPUT_DIR" "$LOG_DIR"
echo "APK,Coverage (%),Initially Healthy,Instrumented Successfully,Healthy After Instrumentation,Instrumentation Time (s)" > "$CSV_FILE"

wait_for_boot() {
  echo "Waiting for emulator to boot..."
  adb -s "$ANDROID_SERIAL" wait-for-device
  until [[ "$(adb -s "$ANDROID_SERIAL" shell getprop sys.boot_completed | tr -d '\r')" == "1" ]]; do
    sleep 5
  done
  sleep 5
  echo "Boot completed on $EMULATOR_NAME."
}

start_emulator() {
  if ! adb -s "$ANDROID_SERIAL" get-state >/dev/null 2>&1; then
    echo "Starting emulator $EMULATOR_NAME on port $EMULATOR_PORT..."
    emulator -avd "$EMULATOR_NAME" -port "$EMULATOR_PORT" -no-window -no-audio -memory 2048 -wipe-data -no-snapshot-load -no-snapshot-save > /dev/null 2>&1 &
    wait_for_boot
  fi
}

restart_emulator() {
  echo "Restarting emulator $EMULATOR_NAME..."
  adb -s "$ANDROID_SERIAL" emu kill
  sleep 10
  start_emulator
}

start_emulator
adb -s "$ANDROID_SERIAL" shell mkdir -p /sdcard/Download

initially_healthy=0
instrumented_successfully=0
healthy_after_instrumentation=0
total_apps=$(ls "$INPUT_DIR"/*.apk | wc -l)
apk_counter=0


for apk in "$INPUT_DIR"/*.apk; do
  ((apk_counter++))

  echo -e "\n$(date '+%Y-%m-%d %H:%M:%S') - apk_counter is:  $apk_counter"
  if (( apk_counter % 10 == 0 )); then
    if [ "$apk_counter" -lt "$total_apps" ]; then
      restart_emulator
    fi
  fi

  apk_filename=$(basename "$apk")
  apk_name="${apk_filename%.apk}"
  workdir="$OUTPUT_DIR/$apk_name"
  wd_dir="$workdir/wd"
  mkdir -p "$workdir" "$wd_dir"

  adb -s "$ANDROID_SERIAL" logcat -c

  initially_healthy_flag=1
  instrumented_success_flag=0
  healthy_after_instr_flag=0

  rm -rf "$wd_dir"
  start_instr_time=$(date +%s)
  instrument_output=$(acv instrument "$apk" -g method --wd "$wd_dir")
  end_instr_time=$(date +%s)
  instr_duration=$((end_instr_time - start_instr_time))
  echo "$instrument_output" > "$workdir/instrument_output.log"

  package_name_instr=$(echo "$instrument_output" | grep "package name:" | awk -F: '{print $2}' | xargs)

  if [ -z "$package_name_instr" ]; then
    echo "$apk_filename,0.0,$initially_healthy_flag,0,0,$instr_duration" >> "$CSV_FILE"
    continue
  else
    instrumented_success_flag=1
    ((instrumented_successfully++))
    echo "Instrumentation succeeded"
  fi

  instr_apk="$wd_dir/instr_${package_name_instr}.apk"

  if adb -s "$ANDROID_SERIAL" shell pm list packages | grep -q "$package_name_instr"; then
    adb -s "$ANDROID_SERIAL" uninstall "$package_name_instr" >/dev/null 2>&1
  fi

  timeout $ACV_TIMEOUT adb -s "$ANDROID_SERIAL" install "$instr_apk" || {
    echo "$apk_filename,0.0,$initially_healthy_flag,1,0,$instr_duration" >> "$CSV_FILE"
    continue
  }

  # Health check including UI visibility (based on window state)
  BEFORE_WINDOWS=$(adb -s "$ANDROID_SERIAL" shell dumpsys window windows || true)
  adb -s "$ANDROID_SERIAL" shell monkey -p "$package_name_instr" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
  sleep 6
  AFTER_WINDOWS=$(adb -s "$ANDROID_SERIAL" shell dumpsys window windows || true)

  if adb -s "$ANDROID_SERIAL" logcat -d | grep -q "FATAL EXCEPTION\|VerifyError"; then
      healthy_after_instr_flag=0
  elif grep -q "$package_name_instr" <<< "$AFTER_WINDOWS" && ! grep -q "$package_name_instr" <<< "$BEFORE_WINDOWS"; then
      healthy_after_instr_flag=1
      ((healthy_after_instrumentation++))
      echo "Post-instrumentation health check passed and UI visible"
  else
      healthy_after_instr_flag=0
      echo "Post-instrumentation health check failed (UI not visible)"
  fi

    if adb -s "$ANDROID_SERIAL" shell pm list packages | grep -q "$package_name_instr"; then
      adb -s "$ANDROID_SERIAL" uninstall "$package_name_instr" >/dev/null 2>&1
    fi

  timeout $ACV_TIMEOUT adb -s "$ANDROID_SERIAL" install "$instr_apk" || {
    echo "$apk_filename,0.0,$initially_healthy_flag,1,0,$instr_duration" >> "$CSV_FILE"
    continue
  }

  timeout $ACV_TIMEOUT acv activate "$package_name_instr" >> "$workdir/acv_activate.log" 2>&1 || {
    echo "$apk_filename,0.0,$initially_healthy_flag,1,$healthy_after_instr_flag,$instr_duration" >> "$CSV_FILE"
    continue
  }

  adb -s "$ANDROID_SERIAL" shell monkey -p "$package_name_instr" --pct-syskeys 0 -s "$MONKEY_SEED" -v 400 >/dev/null 2>&1
  timeout $ACV_TIMEOUT acv snap "$package_name_instr" --wd "$wd_dir" >> "$workdir/acv_snap.log" 2>&1 || {
    echo "$apk_filename,0.0,$initially_healthy_flag,1,$healthy_after_instr_flag,$instr_duration" >> "$CSV_FILE"
    continue
  }

  timeout $ACV_TIMEOUT acv cover-pickles "$package_name_instr" --wd "$wd_dir" >> "$workdir/cover_pickles_output.log" 2>&1 || {
    echo "$apk_filename,0.0,$initially_healthy_flag,1,$healthy_after_instr_flag,$instr_duration" >> "$CSV_FILE"
    continue
  }

  timeout $ACV_TIMEOUT acv report "$package_name_instr" --wd "$wd_dir" >> "$workdir/report_output.log" 2>&1 || {
    echo "$apk_filename,0.0,$initially_healthy_flag,1,$healthy_after_instr_flag,$instr_duration" >> "$CSV_FILE"
    continue
  }

  report_html="$wd_dir/report/main_index.html"
  if [ -f "$report_html" ]; then
    coverage=$(awk '/<tfoot>/,/<\/tfoot>/' "$report_html" | grep -o '[0-9]\+\.[0-9]\+%' | head -n 1 | sed 's/%//')
    coverage=$(printf "%.2f" "$coverage")
  else
    coverage="0.0"
  fi

  adb -s "$ANDROID_SERIAL" logcat -d > "$workdir/logcat_$package_name_instr.txt"
  adb -s "$ANDROID_SERIAL" logcat -c
  cp "$report_html" "$workdir/acv_main_index.html" >/dev/null 2>&1

  echo "$apk_filename,$coverage,$initially_healthy_flag,$instrumented_success_flag,$healthy_after_instr_flag,$instr_duration" >> "$CSV_FILE"
done

SUMMARY_FILE="$OUTPUT_DIR/summary.txt"
{
  echo "==== $EMULATOR_NAME SUMMARY ===="
  echo "Total Apps: $total_apps"
  echo "Instrumented Successfully: $instrumented_successfully"
  echo "Healthy After Instrumentation: $healthy_after_instrumentation"
  echo "CSV: $CSV_FILE"
} > "$SUMMARY_FILE"
