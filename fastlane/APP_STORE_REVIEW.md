# App Store launch review

The first App Store version currently in App Store Connect is `1.0` and is still a draft. The complete local listing snapshot for all 17 app languages is in `fastlane/metadata/1.0/<locale>/`; the app name is `GIFBloom` in every locale. Local metadata now includes the marketing, privacy, and support page URLs. The primary category is Photo & Video. The full App Store Connect baseline is tracked in `fastlane/data/1.0/`.

The listing copy is a draft for review. In particular, please confirm that the privacy statements are accurate and have a fluent speaker review the translations before submission.

## Owner input needed

- Support contact details. The localized public privacy, support, and marketing URLs are in the versioned metadata; App Store Connect still needs those values uploaded.
- App Review contact name, email, and phone number.
- Copyright holder text for the store listing.
- Confirmation of the app privacy answers. The source currently processes selected photos and videos locally and has no analytics, account, or network SDK. The draft privacy manifest declares no collected data or tracking.
- Age rating and content-rights questionnaire answers.
- The exact features GIFBloom Pro should unlock. The app now presents the weekly subscription and lifetime purchase with StoreKit views and checks verified entitlements, but no app features are gated until the Pro benefit scope is confirmed.
- Real App Store screenshots. Existing UI audit images show empty smoke-test screens and are not suitable for the product page. Please provide representative project media or approve creating screenshots from a seeded demo project.
- Release version alignment. The Xcode project is `1.03` / build `7`; the editable App Store version is `1.0`, has no build attached, and the latest uploaded build is `1.03` / build `6`. These version numbers need to match before submission.

## Still incomplete in App Store Connect

- No App Store screenshots are attached to the `1.0` version.
- Privacy policy and support URLs are blank.
- No age-rating declaration, copyright text, or App Review contact details are set.
- The app version has no build attached.
- The weekly subscription and lifetime purchase still report `MISSING_METADATA`; they have localized names and descriptions, but lack App Review screenshots and review information.
- The current price snapshot is tracked for all 175 configured territories: the weekly subscription is USD 1.99 per week in the United States, and lifetime is USD 24.99 in the United States. China and the United States have manual territory prices for lifetime; other lifetime territories use App Store Connect generated prices. The intended price of the app itself is not confirmed and is deliberately left unset in the Fastlane data.
- Both products have localized display names and descriptions in all 17 app locales. These localizations are still in `PREPARE_FOR_SUBMISSION`; they do not clear the product-level `MISSING_METADATA` status without the missing review materials.
- The app settings now link to the live privacy and support pages and the Apple Standard EULA. App Store Connect's privacy policy and support URL fields still need to be updated after the page copy is reviewed.
- No App Privacy response has been published. Review the data-collection declaration before publishing it.

No build was run, and nothing has been submitted for App Review.
