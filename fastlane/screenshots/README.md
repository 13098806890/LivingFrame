# App Store screenshots

Store screenshots belong under `fastlane/screenshots/<store-version>/<App Store locale>/`, with image files directly inside each locale directory so Deliver can identify them. The upload lane uses this path and refuses to upload when the version folder is absent.

## Current checked-in sets

- `1.03/` contains five iPhone screenshots in each of 17 App Store locale folders. The `zh-Hans` and `zh-Hant` images use Chinese artwork. The other 15 folders reuse English artwork, including English marketing headlines and English app UI; they are not localized screenshot sets.
- `1.03/en-US/` also contains iPad screenshots. They are English-only.
- `1.06/` contains six 6.9-inch iPhone screenshots for each of the same 17 App Store locales (102 PNGs total, 1320×2868 px). The app screens are captured from the localized app with representative demo media, then framed with localized feature headlines. This set does not add iPad screenshots.
- `1.07/` is the current release candidate and mirrors the optimized 1.06 local set: six localized iPhone screenshots for each of 17 locales (102 PNGs total). The original `1.06/` directory remains as a local snapshot; neither set has been uploaded by this task.

The 1.03 artwork files are flattened PNGs. The original editable source path previously documented as `/Users/doxie/Desktop/GIFBloom/app-store-drafts` is not present in this workspace. Do not make translated duplicates of these images and label them as localized: the app UI remains English and the source has no editable text layers.

## 1.06 asset requirements

The local screenshot set is prepared under `1.06/<locale>/` for all 17 locales. Each locale contains six product screens in this order: timeline editor, stickers, export options, canvas, text, and crop. Headlines and visible app UI are localized. `../creative-assets/store-demo-person.png` is the fictional adult demo image used in the capture; `../../Scripts/compose_aso_screenshots.swift` composes the localized headline frames from XCTest screenshots.

Review the localized wording and final screenshots before upload. The screenshot upload lane is intentionally not run as part of local preparation. See `fastlane/APP_STORE_REVIEW.md` for the release checklist.
