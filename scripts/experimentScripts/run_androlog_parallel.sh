#!/bin/bash

INPUT_DIR="$1"
OUTPUT_DIR="${2:-results}"
EMULATOR_NAME="$3"
EMULATOR_PORT="${4:-5556}"

CSV_FILE="$OUTPUT_DIR/coverage_results.csv"
LOG_DIR="$OUTPUT_DIR/logs"
RESULT_DIR="$OUTPUT_DIR/result"
MONKEY_SEED=12345
LOGCAT_FILTER="MY_SUPER_LOG"
ANDROLOG_JAR="/home/fuad/tools/AndroLog/target/androlog-0.1-jar-with-dependencies.jar"
PLATFORMS_PATH="/home/fuad/android-sdk-linux/platforms"

if [ -z "$INPUT_DIR" ] || [ -z "$EMULATOR_NAME" ]; then
  echo "Usage: $0 <input_apk_dir> <output_dir> <emulator_name> <emulator_port>"
  exit 1
fi

mkdir -p "$OUTPUT_DIR" "$LOG_DIR" "$RESULT_DIR"
echo "$(date '+%F %T') - Script started on $EMULATOR_NAME (port $EMULATOR_PORT). Monitoring input dir: $INPUT_DIR" | tee -a "$LOG_DIR/heartbeat.log"

echo "APK,Coverage (%),Initially Healthy,Instrumented Successfully,Healthy After Instrumentation,Instrumentation Time (s)" > "$CSV_FILE"

export ANDROID_SERIAL="emulator-${EMULATOR_PORT}"

wait_for_boot() {
  echo "Waiting for emulator $EMULATOR_NAME to boot..."
  adb -s "$ANDROID_SERIAL" wait-for-device
  until [[ "$(adb -s "$ANDROID_SERIAL" shell getprop sys.boot_completed | tr -d '\r')" == "1" ]]; do
    sleep 5
  done
  echo "$EMULATOR_NAME boot completed."
}

start_emulator() {
  if ! adb -s "$ANDROID_SERIAL" shell getprop sys.boot_completed | grep -q "1"; then
    echo "Starting emulator $EMULATOR_NAME on port $EMULATOR_PORT..."
    emulator -avd "$EMULATOR_NAME" -no-window -no-audio -memory 2048 \
      -port "$EMULATOR_PORT" -wipe-data -no-snapshot-load -no-snapshot-save > /dev/null 2>&1 &
    wait_for_boot
  else
    echo "Emulator $EMULATOR_NAME already running."
  fi
}

restart_emulator() {
  echo "Restarting emulator $EMULATOR_NAME..."
  adb -s "$ANDROID_SERIAL" emu kill
  sleep 10
  start_emulator
}

start_emulator

initially_healthy=0
instrumented_successfully=0
healthy_after_instrumentation=0
total_apps=$(ls "$INPUT_DIR"/*.apk | wc -l)
apk_counter=0

adb -s "$ANDROID_SERIAL" shell mkdir -p /sdcard/Download

for apk in "$INPUT_DIR"/*.apk; do
  ((apk_counter++))

  initially_healthy_flag=1
  instrumented_success_flag=0
  healthy_after_instr_flag=0

  if (( apk_counter % 10 == 0 )); then
    restart_emulator
  fi

  apk_filename=$(basename "$apk")
  apk_name="${apk_filename%.apk}"
  apkdir="$RESULT_DIR/$apk_filename"
  workdir="$OUTPUT_DIR/$apk_name"
  mkdir -p "$workdir"

  adb -s "$ANDROID_SERIAL" shell "rm -rf /sdcard/Download/*" >/dev/null 2>&1
  echo -e "\n$(date '+%Y-%m-%d %H:%M:%S') - Processing $apk_filename on $EMULATOR_NAME"

  package_name=$(aapt dump badging "$apk" | awk -F"'" '/package: name=/{print $2}')

  adb -s "$ANDROID_SERIAL" logcat -c

  start_instr_time=$(date +%s)
  instrument_output=$(
    timeout 3600s java -Xms1G -Xmx8G -XX:+UseG1GC -XX:MaxGCPauseMillis=200 -jar "$ANDROLOG_JAR" \
      -p "$PLATFORMS_PATH" -l "$LOGCAT_FILTER" \
      -o "$RESULT_DIR" -a "$apk" -s 2>&1
  )
  end_instr_time=$(date +%s)
  instr_duration=$((end_instr_time - start_instr_time))
  echo "$instrument_output" > "$workdir/instrument_output.log"

  if echo "$instrument_output" | grep -q "OutOfMemoryError"; then
    echo "Instrumentation OOM for $apk_filename"
    echo "$apk_filename,0.0,$initially_healthy_flag,0,0,$instr_duration" >> "$CSV_FILE"
    continue
  fi

  if [ "${instrument_output%% *}" = "timeout" ]; then
    echo "Instrumentation timed out for $apk_filename"
    echo "$apk_filename,0.0,$initially_healthy_flag,0,0,$instr_duration" >> "$CSV_FILE"
    continue
  fi

  if echo "$instrument_output" | grep -q "The apk is now instrumented"; then
    instrumented_success_flag=1
    ((instrumented_successfully++))
  else
    echo "Instrumentation failed"
    echo "$apk_filename,0.0,$initially_healthy_flag,0,0,$instr_duration" >> "$CSV_FILE"
    continue
  fi

  if adb -s "$ANDROID_SERIAL" shell pm list packages | grep -q "$package_name"; then
    adb -s "$ANDROID_SERIAL" uninstall "$package_name" >/dev/null 2>&1
  fi

  timeout 3600s adb -s "$ANDROID_SERIAL" install "$apkdir" || {
    echo "Install failed"
    echo "$apk_filename,0.0,$initially_healthy_flag,1,0,$instr_duration" >> "$CSV_FILE"
    continue
  }

  adb -s "$ANDROID_SERIAL" logcat -c

# Health check including UI visibility (based on window state)
BEFORE_WINDOWS=$(adb -s "$ANDROID_SERIAL" shell dumpsys window windows || true)
adb -s "$ANDROID_SERIAL" shell monkey -p "$package_name" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
sleep 6
AFTER_WINDOWS=$(adb -s "$ANDROID_SERIAL" shell dumpsys window windows || true)

if adb -s "$ANDROID_SERIAL" logcat -d | grep -q "FATAL EXCEPTION\|VerifyError"; then
    healthy_after_instr_flag=0
elif grep -q "$package_name" <<< "$AFTER_WINDOWS" && ! grep -q "$package_name" <<< "$BEFORE_WINDOWS"; then
    healthy_after_instr_flag=1
    ((healthy_after_instrumentation++))
    echo "Post-instrumentation health check passed and UI visible"
else
    healthy_after_instr_flag=0
    echo "Post-instrumentation health check failed (UI not visible)"
fi

  if adb -s "$ANDROID_SERIAL" shell pm list packages | grep -q "$package_name"; then
    adb -s "$ANDROID_SERIAL" uninstall "$package_name" >/dev/null 2>&1
  fi

  # Reinstall for coverage collection
  timeout 3600s adb -s "$ANDROID_SERIAL" install "$apkdir" || {
    echo "Reinstall for coverage failed"
    echo "$apk_filename,0.0,$initially_healthy_flag,1,0,$instr_duration" >> "$CSV_FILE"
    continue
  }

  logcat_file="$OUTPUT_DIR/${apk_name}_logcat.log"
  adb -s "$ANDROID_SERIAL" logcat | grep "$LOGCAT_FILTER" > "$logcat_file" &
  logcat_pid=$!

  adb -s "$ANDROID_SERIAL" logcat -c
  adb -s "$ANDROID_SERIAL" shell monkey -p "$package_name" --pct-syskeys 0 -s "$MONKEY_SEED" -v 400 >/dev/null 2>&1
  sleep 5
  kill "$logcat_pid"

  coverage_output_file="$OUTPUT_DIR/${apk_name}_coverage.log"

  java -Xms1G -Xmx8G -XX:+UseG1GC -XX:MaxGCPauseMillis=200 -jar "$ANDROLOG_JAR" -p "$PLATFORMS_PATH" -l "$LOGCAT_FILTER" -a "$apkdir" -s -pa "$logcat_file" > "$coverage_output_file" 2>&1

  methods_coverage=$(grep "methods" "$coverage_output_file" | awk -F: '{print $2}' | sed 's/(.*//;s/%//;s/ //g')
  methods_coverage="${methods_coverage:-0.0}"

  echo "$apk_filename,$methods_coverage,$initially_healthy_flag,$instrumented_success_flag,$healthy_after_instr_flag,$instr_duration" >> "$CSV_FILE"
  rm -f "$logcat_file"

done

echo -e "\n==== $EMULATOR_NAME SUMMARY ===="
echo "Total: $total_apps"
echo "Instrumented: $instrumented_successfully"
echo "Healthy After Instr.: $healthy_after_instrumentation"
echo "CSV: $CSV_FILE"

SUMMARY_FILE="$OUTPUT_DIR/summary.txt"
{
  echo "==== $EMULATOR_NAME SUMMARY ===="
  echo "Total Apps: $total_apps"
  echo "Instrumented Successfully: $instrumented_successfully"
  echo "Healthy After Instrumentation: $healthy_after_instrumentation"
} > "$SUMMARY_FILE"

