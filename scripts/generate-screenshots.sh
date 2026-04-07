#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

OUTPUT_DIR="${PIMUX_SCREENSHOT_OUTPUT_DIR:-/tmp/pimux2000-screenshots}"
RESULT_DIR="${PIMUX_SCREENSHOT_RESULT_DIR:-/tmp/pimux2000-screenshot-results}"
DERIVED_DATA_PATH="${PIMUX_SCREENSHOT_DERIVED_DATA_PATH:-/tmp/pimux2000-screenshot-derived-data}"
DEVICE_NAMES_CSV="${PIMUX_SCREENSHOT_DEVICES:-iPhone 16 Pro,iPad Pro 13-inch (M4)}"
STATUS_BAR_ENABLED="${PIMUX_SCREENSHOT_STATUS_BAR:-1}"
APPEARANCE="${PIMUX_SCREENSHOT_APPEARANCE:-dark}"
SIGNAL_CONFIG_PATH="/tmp/pimux2000-screenshot-signal-dir.txt"

mkdir -p "$OUTPUT_DIR" "$RESULT_DIR" "$DERIVED_DATA_PATH"
rm -f "$SIGNAL_CONFIG_PATH"
trap 'rm -f "$SIGNAL_CONFIG_PATH"' EXIT

SIMCTL_JSON="$(mktemp)"
xcrun simctl list devices available -j > "$SIMCTL_JSON"

mapfile -t RESOLVED_DEVICES < <(
	DEVICE_NAMES_CSV="$DEVICE_NAMES_CSV" \
	SIMCTL_JSON="$SIMCTL_JSON" \
	python3 - <<'PY'
import json
import os
import re
import sys

simctl_json = os.environ["SIMCTL_JSON"]
device_names = [name.strip() for name in os.environ["DEVICE_NAMES_CSV"].split(",") if name.strip()]

with open(simctl_json, "r", encoding="utf-8") as file:
    data = json.load(file)

resolved = []
missing = []
for requested_name in device_names:
    best = None
    best_score = None
    best_runtime = None

    for runtime, devices in data.get("devices", {}).items():
        match = re.search(r"iOS-(\d+(?:-\d+)*)$", runtime)
        if match is None:
            continue

        score = tuple(int(component) for component in match.group(1).split("-"))
        for device in devices:
            if device.get("name") != requested_name:
                continue
            if not device.get("isAvailable", True):
                continue

            if best is None or score > best_score:
                best = device
                best_score = score
                best_runtime = match.group(1).replace("-", ".")

    if best is None:
        missing.append(requested_name)
        continue

    resolved.append((requested_name, best["udid"], best_runtime))

if missing:
    print("Unable to resolve simulators for: " + ", ".join(missing), file=sys.stderr)
    sys.exit(1)

for requested_name, udid, runtime in resolved:
    print(f"{requested_name}\t{udid}\t{runtime}")
PY
)

rm -f "$SIMCTL_JSON"

if [[ ${#RESOLVED_DEVICES[@]} -eq 0 ]]; then
	echo "No simulator destinations resolved." >&2
	exit 1
fi

slugify() {
	printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//'
}

normalize_image_to_landscape_if_needed() {
	local image_path="$1"
	local dimensions
	dimensions="$(sips -g pixelWidth -g pixelHeight "$image_path" 2>/dev/null)"
	local width
	local height
	width="$(awk '/pixelWidth:/ { print $2 }' <<< "$dimensions")"
	height="$(awk '/pixelHeight:/ { print $2 }' <<< "$dimensions")"

	if [[ -n "$width" && -n "$height" && "$height" -gt "$width" ]]; then
		local rotated_path="${image_path}.rotated.png"
		sips -r 270 "$image_path" --out "$rotated_path" >/dev/null
		mv "$rotated_path" "$image_path"
	fi
}

assert_images_are_landscape() {
	local device_output_dir="$1"
	DEVICE_OUTPUT_DIR="$device_output_dir" swift - <<'SWIFT'
import AppKit
import Foundation

let deviceOutputDir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["DEVICE_OUTPUT_DIR"]!)
let fileManager = FileManager.default
let imageURLs = try fileManager.contentsOfDirectory(at: deviceOutputDir, includingPropertiesForKeys: nil)
	.filter { ["png", "jpg", "jpeg", "heic", "heif", "webp"].contains($0.pathExtension.lowercased()) }

var portraitImages: [String] = []
for imageURL in imageURLs {
	guard let image = NSImage(contentsOf: imageURL),
	      let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
	else {
		continue
	}

	if cgImage.height > cgImage.width {
		portraitImages.append(imageURL.lastPathComponent)
	}
}

if !portraitImages.isEmpty {
	fputs("iPad screenshots are still portrait: \(portraitImages.joined(separator: ", "))\n", stderr)
	exit(1)
}
SWIFT
}

run_external_capture_test() {
	local device_name="$1"
	local device_udid="$2"
	local device_slug="$3"
	local device_output_dir="$4"
	local screenshot_name="$5"
	local test_identifier="$6"
	local signal_dir="$RESULT_DIR/${device_slug}-${screenshot_name}-signals"
	local result_bundle_path="$RESULT_DIR/${device_slug}-${screenshot_name}.xcresult"
	local log_path="$RESULT_DIR/${device_slug}-${screenshot_name}.log"
	local ready_file="$signal_dir/${screenshot_name}.ready"
	local captured_file="$signal_dir/${screenshot_name}.captured"
	local output_path="$device_output_dir/${screenshot_name}.png"

	rm -rf "$signal_dir" "$result_bundle_path"
	mkdir -p "$signal_dir"

	printf '%s\n' "$signal_dir" > "$SIGNAL_CONFIG_PATH"

	echo "==> Running $test_identifier on $device_name"
	xcodebuild test \
		-project "$ROOT_DIR/pimux2000.xcodeproj" \
		-scheme pimux2000 \
		-destination "id=$device_udid" \
		-parallel-testing-enabled NO \
		-derivedDataPath "$DERIVED_DATA_PATH" \
		-only-testing:"$test_identifier" \
		-resultBundlePath "$result_bundle_path" \
		>"$log_path" 2>&1 &
	local xcodebuild_pid=$!

	for _ in {1..120}; do
		if [[ -f "$ready_file" ]]; then
			break
		fi
		if ! kill -0 "$xcodebuild_pid" >/dev/null 2>&1; then
			wait "$xcodebuild_pid"
			rm -f "$SIGNAL_CONFIG_PATH"
			cat "$log_path" >&2
			return 1
		fi
		sleep 1
	done

	if [[ ! -f "$ready_file" ]]; then
		kill "$xcodebuild_pid" >/dev/null 2>&1 || true
		wait "$xcodebuild_pid" >/dev/null 2>&1 || true
		rm -f "$SIGNAL_CONFIG_PATH"
		echo "Timed out waiting for $screenshot_name to become ready for external capture." >&2
		cat "$log_path" >&2
		return 1
	fi

	xcrun simctl io "$device_udid" screenshot "$output_path" >/dev/null
	normalize_image_to_landscape_if_needed "$output_path"
	touch "$captured_file"
	wait "$xcodebuild_pid"
	rm -f "$SIGNAL_CONFIG_PATH"
	echo "$output_path"
}

for resolved_device in "${RESOLVED_DEVICES[@]}"; do
	IFS=$'\t' read -r DEVICE_NAME DEVICE_UDID DEVICE_RUNTIME <<< "$resolved_device"
	DEVICE_SLUG="$(slugify "$DEVICE_NAME")"
	RESULT_BUNDLE_PATH="$RESULT_DIR/${DEVICE_SLUG}.xcresult"
	EXPORT_PATH="$RESULT_DIR/${DEVICE_SLUG}-attachments"
	DEVICE_OUTPUT_DIR="$OUTPUT_DIR/$DEVICE_SLUG"

	rm -rf "$RESULT_BUNDLE_PATH" "$EXPORT_PATH" "$DEVICE_OUTPUT_DIR"
	mkdir -p "$DEVICE_OUTPUT_DIR"

	echo "==> Booting $DEVICE_NAME (iOS $DEVICE_RUNTIME)"
	xcrun simctl boot "$DEVICE_UDID" >/dev/null 2>&1 || true
	xcrun simctl bootstatus "$DEVICE_UDID" -b

	if [[ "$STATUS_BAR_ENABLED" != "0" ]]; then
		xcrun simctl status_bar "$DEVICE_UDID" override \
			--time 9:41 \
			--dataNetwork wifi \
			--wifiMode active \
			--wifiBars 3 \
			--cellularMode active \
			--cellularBars 4 \
			--batteryState charged \
			--batteryLevel 100 >/dev/null || true
	fi

	ORIGINAL_APPEARANCE="$(xcrun simctl ui "$DEVICE_UDID" appearance 2>/dev/null || echo unknown)"
	if [[ "$APPEARANCE" == "light" || "$APPEARANCE" == "dark" ]]; then
		xcrun simctl ui "$DEVICE_UDID" appearance "$APPEARANCE" >/dev/null
	fi

	if [[ "$DEVICE_NAME" == iPad* ]]; then
		run_external_capture_test \
			"$DEVICE_NAME" \
			"$DEVICE_UDID" \
			"$DEVICE_SLUG" \
			"$DEVICE_OUTPUT_DIR" \
			"app-overview" \
			"pimux2000UITests/ScreenshotTests/testAppOverviewScreenshot"
		run_external_capture_test \
			"$DEVICE_NAME" \
			"$DEVICE_UDID" \
			"$DEVICE_SLUG" \
			"$DEVICE_OUTPUT_DIR" \
			"transcript" \
			"pimux2000UITests/ScreenshotTests/testTranscriptScreenshot"
		run_external_capture_test \
			"$DEVICE_NAME" \
			"$DEVICE_UDID" \
			"$DEVICE_SLUG" \
			"$DEVICE_OUTPUT_DIR" \
			"slash-commands" \
			"pimux2000UITests/ScreenshotTests/testSlashCommandsScreenshot"
		assert_images_are_landscape "$DEVICE_OUTPUT_DIR"
	else
		echo "==> Running ScreenshotTests on $DEVICE_NAME"
		xcodebuild test \
			-project "$ROOT_DIR/pimux2000.xcodeproj" \
			-scheme pimux2000 \
			-destination "id=$DEVICE_UDID" \
			-parallel-testing-enabled NO \
			-derivedDataPath "$DERIVED_DATA_PATH" \
			-only-testing:pimux2000UITests/ScreenshotTests \
			-resultBundlePath "$RESULT_BUNDLE_PATH"

		echo "==> Exporting attachments from $RESULT_BUNDLE_PATH"
		xcrun xcresulttool export attachments \
			--path "$RESULT_BUNDLE_PATH" \
			--output-path "$EXPORT_PATH"

		EXPORT_PATH="$EXPORT_PATH" DEVICE_OUTPUT_DIR="$DEVICE_OUTPUT_DIR" python3 - <<'PY'
import json
import os
import re
import shutil
from pathlib import Path

export_path = Path(os.environ["EXPORT_PATH"])
device_output_dir = Path(os.environ["DEVICE_OUTPUT_DIR"])
manifest_path = export_path / "manifest.json"

entries = json.loads(manifest_path.read_text(encoding="utf-8"))
if not entries:
    raise SystemExit("No screenshot attachments were exported.")

image_extensions = {".png", ".jpg", ".jpeg", ".heic", ".heif", ".webp"}
seen = {}
generated = []
for entry in entries:
    for attachment in entry.get("attachments", []):
        source = export_path / attachment["exportedFileName"]
        suggested_name = attachment.get("suggestedHumanReadableName") or source.name
        suggested_path = Path(suggested_name)
        extension = (suggested_path.suffix or source.suffix or ".png").lower()
        if extension not in image_extensions:
            continue

        stem = re.sub(r"_[0-9]+_[0-9A-Fa-f-]+$", "", suggested_path.stem)
        if not stem:
            stem = source.stem

        count = seen.get(stem, 0) + 1
        seen[stem] = count
        final_name = f"{stem}{'' if count == 1 else f'-{count}'}{extension}"
        destination = device_output_dir / final_name
        shutil.copy2(source, destination)
        generated.append(destination)

if not generated:
    raise SystemExit("No screenshot images were exported.")

for path in generated:
    print(path)
PY
	fi

	if [[ "$STATUS_BAR_ENABLED" != "0" ]]; then
		xcrun simctl status_bar "$DEVICE_UDID" clear >/dev/null 2>&1 || true
	fi
	if [[ "$ORIGINAL_APPEARANCE" == "light" || "$ORIGINAL_APPEARANCE" == "dark" ]]; then
		xcrun simctl ui "$DEVICE_UDID" appearance "$ORIGINAL_APPEARANCE" >/dev/null 2>&1 || true
	fi

done

echo
echo "Generated screenshots:"
find "$OUTPUT_DIR" -type f | sort
