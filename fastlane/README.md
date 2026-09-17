# GIFBloom App Store data

This directory is the version-controlled source for App Store Connect listing content and the related Fastlane release inputs. The initial full baseline is the editable App Store version `1.0`.

## Layout and versioning

- `metadata/1.0/` is the complete first-version Deliver metadata snapshot for all 17 app locales. App Store display name stays `GIFBloom` in every locale.
- `data/1.0/` is the full App Store Connect baseline: app settings and review state, privacy and age-rating status, in-app purchase definitions, localized purchase text, and the current territory price schedules.
- `screenshots/<version>/<locale>/` is where real App Store screenshots go. Nothing has been generated as a store screenshot because the existing UI audit images are not representative product screenshots.
- For later store versions, add `metadata/<version>/` with only the changed Deliver fields and locales. In `data/<version>/`, add only the changed files or a `changes.json` RFC 7396 merge patch. Do not copy the full `1.0` baseline into later versions.

Keep App Store version directories aligned with the version being prepared in App Store Connect. The current Xcode marketing version is `1.03`, while the editable App Store Connect version is `1.0`; align the build and store version before uploading a build.

## Credentials

`fastlane/.env` is local and ignored by Git. It points Fastlane at the local App Store Connect API key file; the `.p8` itself must remain outside the repository. Use `fastlane/.env.example` when setting up another machine.

## Fastlane lanes

From the repository root:

```sh
fastlane ios upload_metadata version:1.0
fastlane ios upload_screenshots version:1.0
fastlane ios upload_build ipa:/absolute/path/GIFBloom.ipa
fastlane ios download_store_metadata version:1.0
```

These lanes do not submit the app for review or release it. Screenshot uploads stop until localized image assets are added. `set_app_price` requires a confirmed Fastlane price tier and `confirm:true`; the initial app price is intentionally marked unconfirmed.

Fastlane Deliver uploads the app listing metadata and screenshots and supports an app price tier. Subscription and in-app purchase data is kept in `data/1.0/products/`; Deliver does not upload those product localizations or price schedules as part of `upload_metadata`. Apple exposes those operations through the App Store Connect API, with version-based review metadata for in-app purchases. The snapshots are ready for review and future API-based syncing, but this task does not write product changes to App Store Connect.

References: [Fastlane `upload_to_app_store`](https://docs.fastlane.tools/actions/upload_to_app_store/), [Apple in-app purchase management](https://developer.apple.com/documentation/appstoreconnectapi/in-app-purchase), [Apple in-app purchase versions](https://developer.apple.com/documentation/appstoreconnectapi/in-app-purchase-versions).

## Current blockers

See [`APP_STORE_REVIEW.md`](APP_STORE_REVIEW.md) for the owner-review checklist. In particular, the app price, copyright, App Review contact, age-rating and privacy answers, app screenshots, and IAP review screenshots/notes still need confirmation or assets.
