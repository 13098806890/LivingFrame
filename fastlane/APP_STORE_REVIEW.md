# App Store release review — 1.08

## Live release state — 2026-11-10

- **App Store version:** `1.08` is in `PREPARE_FOR_SUBMISSION`; it has no build attached.
- **Candidate build:** App Store Connect contains build `18` for app version `1.08`; its processing state is `VALID` and it is not expired. It must still be selected for version `1.08`. A separate build numbered `18` is associated with version `2.07`, so verify the app version when selecting a build.
- **Source revision:** pushed `main` is `9999367a`. The checked-out project file locally sets the app to `1.08` / build `18`, but those version changes are uncommitted; the pushed project still says `1.07` / build `17`. App Store Connect does not show a source commit for build `18`, so its correspondence to the pushed source has not been verified.
- **Localized metadata:** What's New and Promotional Text are present for all 17 locales in App Store Connect. The `upload_metadata` lane succeeded on 2026-11-10 and its precheck reported no placeholder text or broken URLs. The lane uploaded metadata only; it did not upload a build or submit the version.
- **Screenshots:** App Store Connect has screenshot assets attached in all 17 locales: five images per locale; `en-US` has three sets (15 images) for iPhone 6.5-inch, iPad 11-inch, and iPad 12.9-inch. The local repository has no reviewed 1.08 screenshot set, so verify the current images still represent the 1.08 UI before submission.
- **App Review details:** contact name, phone, and email are set; review notes are present; a demo account is not required.
- **Age rating:** the 1.08 App Info record has a 4+ rating.
- **China mainland availability:** App Store Connect currently reports China mainland as `AVAILABLE`. This shows no current territory availability block, but does not by itself document the basis of any ICP filing exemption.

## Release blockers and final checks

1. Attach the valid build `18` for app version `1.08`. Apple requires a selected build and complete required metadata before a version can be submitted for review: [Submit an app](https://developer.apple.com/help/app-store-connect/manage-submissions-to-app-review/submit-an-app).
2. Confirm the selected binary contains the intended source, including the removal of the temporary Pro override. The build predates the `9999367a` push, and no source-to-build link was available in the inspected App Store Connect record.
3. Review the attached screenshots against the current app UI. Apple’s current accepted screenshot sizes and fallback rules are listed in [Screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/).
4. Reconfirm App Privacy answers and content-rights declarations against the selected binary and current SDK/data flows. These were not independently verified in this review; Apple requires privacy disclosures to cover the app and third-party partners: [Manage app privacy](https://developer.apple.com/help/app-store-connect/manage-app-information/manage-app-privacy/).

The version is **not ready to submit yet** because no build is attached. No build upload, review submission, or release action was performed during this review.
