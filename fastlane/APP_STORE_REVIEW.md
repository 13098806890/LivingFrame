# App Store release review — 1.07

## Release baseline

- **Local release candidate:** `1.07` / build `17` in the Xcode project.
- **Last documented App Store Connect baseline:** published `1.06` / build `15`, checked on 2026-10-27. Recheck the live version, build, and status before submitting 1.07.
- **Localized metadata:** `fastlane/metadata/1.07/<locale>/` contains all 17 App Store locales. What's New and promotional text were uploaded to App Store Connect on 2026-10-30; this metadata-only upload did not include screenshots or a build and did not submit the version for review.
- **Local screenshot candidate:** `fastlane/screenshots/1.07/<locale>/` contains six screenshots per locale (102 PNGs total). The 1.07 files currently mirror the 1.06 set; review the actual 1.07 set before upload.
- **Fastlane data snapshot:** `fastlane/data/1.07/` has not been generated. This is an App Store Connect state/pricing snapshot, not a prerequisite for the local app build or review of metadata and screenshots. Generate it after confirming the live 1.07 record; do not infer live state from local files.
- **Historical data snapshot:** `fastlane/data/1.0/` was captured on 2026-09-17. It is not evidence of the current release version.

## Latest metadata upload

- **Date:** 2026-10-30.
- **Result:** Fastlane `upload_metadata` completed successfully for version 1.07 after updating localized What's New and promotional text.
- **Precheck note:** The first upload attempt reported the Turkish privacy policy URL as unreachable; the final successful retry passed the URL check. No broken-URL warning remained in the completed run.
- **Scope:** No build or screenshots were uploaded, and 1.07 was not submitted for review or released.

## 1.07 review items

### Localized product screenshots

Review all six locale-specific screenshots in `fastlane/screenshots/1.07/<locale>/`, including the two Chinese sets and RTL layout for `ar-SA`. The set uses localized app screens and fictional adult demo media. The files are flattened composites; if text or layout needs correction, regenerate them from the capture and composition workflow rather than editing the flattened image as if it were source artwork.

The screenshot upload lane is intentionally not run during local preparation. Upload only after the 1.07 screenshots and metadata have been reviewed.

### App Store Connect reconciliation

Read the live App Store Connect record before upload. Confirm the editable 1.07 version, build `17` attachment, metadata, screenshots, and review submission state. Then capture the confirmed state in `fastlane/data/1.07/` using the Fastlane snapshot workflow and update this checklist with the observation date. The missing snapshot does not block local development or candidate review.

## Other submission checks

- App Review contact information, age-rating answers, and content-rights answers are complete.
- App Privacy answers match the submitted build, privacy manifest, SDKs, and current data flows.
- Pro benefit wording matches the submitted build, including watermark behavior and the maximum extraction duration.
- Subscription products and available purchase flows match the submitted build and App Store Connect state.
- Store descriptions, localized metadata, support/privacy/marketing URLs, and review notes are current.

No App Store Connect upload, metadata mutation, binary upload, review submission, or release was performed during local preparation.
