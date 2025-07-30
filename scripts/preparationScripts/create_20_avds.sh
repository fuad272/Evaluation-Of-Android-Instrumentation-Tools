#!/bin/bash

BASE_AVD_NAME="Android11_API30_Play"
NEW_AVD_PREFIX="Android11_API30"
AVD_MANAGER="/home/fuad/android-sdk-linux/cmdline-tools/latest/bin/avdmanager"

if [[ ! -x "$AVD_MANAGER" ]]; then
  echo "avdmanager not found at: $AVD_MANAGER"
  exit 1
fi

echo "Creating 20 AVDs based on system-image: android-30 / google_apis_playstore / x86"

for i in $(seq 1 20); do
  NEW_NAME="${NEW_AVD_PREFIX}_$i"
  echo "Creating $NEW_NAME ..."

  echo "no" | "$AVD_MANAGER" create avd \
    -n "$NEW_NAME" \
    -k "system-images;android-30;google_apis_playstore;x86" \
    --device "pixel_xl" \
    --force

  if [[ $? -ne 0 ]]; then
    echo "Failed to create AVD: $NEW_NAME"
    exit 1
  fi
done

echo "All 20 AVDs created successfully."
