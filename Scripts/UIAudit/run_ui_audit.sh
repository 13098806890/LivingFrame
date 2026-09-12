#!/bin/bash

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
DEVICE_NAME="${UI_AUDIT_DEVICE:-iPhone 17 Pro}"
AUDIT_PROFILE="${UI_AUDIT_PROFILE:-full}"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
OUTPUT_DIR="${UI_AUDIT_OUTPUT:-${PROJECT_ROOT}/Artifacts/UIAudit/${TIMESTAMP}}"
ATTACHMENTS_DIR="${OUTPUT_DIR}/attachments"
BUILD_LOG="${OUTPUT_DIR}/xcodebuild.log"
APP_LOG="${OUTPUT_DIR}/app.log"

mkdir -p "${OUTPUT_DIR}" "${ATTACHMENTS_DIR}"

if ! command -v xcodebuild >/dev/null 2>&1 || ! command -v xcrun >/dev/null 2>&1; then
    echo "error: Xcode command-line tools are required" >&2
    exit 2
fi

DEVICE_JSON="$(xcrun simctl list devices available -j)" || exit 2
DEVICE_UDID="$(printf '%s' "${DEVICE_JSON}" | UI_AUDIT_RESOLVE_DEVICE="${DEVICE_NAME}" /usr/bin/python3 -c '
import json, os, sys
payload = json.load(sys.stdin)
requested = os.environ["UI_AUDIT_RESOLVE_DEVICE"]
for runtime_devices in payload.get("devices", {}).values():
    for device in runtime_devices:
        if device.get("isAvailable") and device.get("name") == requested:
            print(device["udid"])
            raise SystemExit(0)
raise SystemExit(1)
' 2>/dev/null)" || {
    echo "error: no available Simulator named '${DEVICE_NAME}'" >&2
    echo "Set UI_AUDIT_DEVICE to a name shown by: xcrun simctl list devices available" >&2
    exit 2
}

{
    echo "project_root=${PROJECT_ROOT}"
    echo "device_name=${DEVICE_NAME}"
    echo "device_udid=${DEVICE_UDID}"
    echo "profile=${AUDIT_PROFILE}"
    echo "started_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "xcode=$(xcodebuild -version | tr '\n' ' ')"
} > "${OUTPUT_DIR}/metadata.env"

echo "Booting ${DEVICE_NAME} (${DEVICE_UDID})"
xcrun simctl boot "${DEVICE_UDID}" >/dev/null 2>&1 || true
xcrun simctl bootstatus "${DEVICE_UDID}" -b

DESTINATION="platform=iOS Simulator,id=${DEVICE_UDID}"
TEST_STATUS=0

echo "Building LivingFrame UI tests"
set +e
xcodebuild build-for-testing \
    -project "${PROJECT_ROOT}/LivingFrame.xcodeproj" \
    -scheme LivingFrame \
    -destination "${DESTINATION}" \
    CODE_SIGNING_ALLOWED=NO \
    2>&1 | tee "${BUILD_LOG}"
BUILD_STATUS=${PIPESTATUS[0]}
set -e

if [[ "${BUILD_STATUS}" -ne 0 ]]; then
    TEST_STATUS="${BUILD_STATUS}"
else
    run_phase() {
        local phase_name="$1"
        local test_name="$2"
        local appearance="$3"
        local content_size="$4"
        local result_bundle="${OUTPUT_DIR}/${phase_name}.xcresult"
        local phase_attachments="${ATTACHMENTS_DIR}/${phase_name}"

        echo "Configuring ${phase_name}: appearance=${appearance}, content-size=${content_size}"
        xcrun simctl ui "${DEVICE_UDID}" appearance "${appearance}"
        xcrun simctl ui "${DEVICE_UDID}" content_size "${content_size}"

        # Reset only LivingFrame so the audit starts from a deterministic app
        # state without erasing the user's entire Simulator.
        xcrun simctl uninstall "${DEVICE_UDID}" com.livingframe.app >/dev/null 2>&1 || true

        mkdir -p "${phase_attachments}"
        set +e
        xcodebuild test-without-building \
            -project "${PROJECT_ROOT}/LivingFrame.xcodeproj" \
            -scheme LivingFrame \
            -destination "${DESTINATION}" \
            -resultBundlePath "${result_bundle}" \
            "-only-testing:LivingFrameUITests/LivingFrameUITests/${test_name}" \
            CODE_SIGNING_ALLOWED=NO \
            2>&1 | tee -a "${BUILD_LOG}"
        local phase_status=${PIPESTATUS[0]}
        set -e

        if [[ "${phase_status}" -ne 0 ]]; then
            TEST_STATUS="${phase_status}"
        fi

        if [[ -d "${result_bundle}" ]]; then
            xcrun xcresulttool export attachments \
                --path "${result_bundle}" \
                --output-path "${phase_attachments}" || true
            /usr/bin/python3 "${SCRIPT_DIR}/normalize_attachments.py" "${phase_attachments}" || true
        fi
    }

    echo "Running LivingFrame visual audit (${AUDIT_PROFILE})"
    if [[ "${AUDIT_PROFILE}" == "smoke" ]]; then
        run_phase "smoke" "testSmokeVisualAudit" "light" "large"
    elif [[ "${AUDIT_PROFILE}" == "functional" ]]; then
        run_phase "functional" "testFunctionalWorkflowAudit" "light" "large"
    else
        run_phase "functional" "testFunctionalWorkflowAudit" "light" "large"
        run_phase "standard" "testStandardVisualAudit" "light" "large"
        run_phase "dark" "testDarkAppearanceVisualAudit" "dark" "large"
        run_phase "accessibility" "testAccessibilityTextVisualAudit" \
            "light" "accessibility-extra-extra-extra-large"
    fi
fi

# Leave the shared Simulator in a conventional state after auditing.
xcrun simctl ui "${DEVICE_UDID}" appearance light || true
xcrun simctl ui "${DEVICE_UDID}" content_size large || true

xcrun simctl spawn "${DEVICE_UDID}" log show \
    --style compact \
    --last 15m \
    --predicate 'process == "LivingFrame"' > "${APP_LOG}" 2>&1 || true

{
    echo "finished_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "test_status=${TEST_STATUS}"
} >> "${OUTPUT_DIR}/metadata.env"

printf '%s\n' "${OUTPUT_DIR}" > "${PROJECT_ROOT}/Artifacts/UIAudit/latest.txt"

echo
echo "Audit artifacts: ${OUTPUT_DIR}"
echo "Screenshots:     ${ATTACHMENTS_DIR}"
echo "Test status:     ${TEST_STATUS}"
exit "${TEST_STATUS}"
