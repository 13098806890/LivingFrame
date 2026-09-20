# App Store launch review

The first App Store version currently in App Store Connect is `1.0` and is still a draft. The complete local listing snapshot for all 17 app languages is in `fastlane/metadata/1.0/<locale>/`; the app name is `GIFBloom` in every locale. Local metadata now includes the marketing, privacy, and support page URLs. The primary category is Photo & Video. The full App Store Connect baseline is tracked in `fastlane/data/1.0/`.

The listing copy is a draft for review. In particular, please confirm that the privacy statements are accurate and have a fluent speaker review the translations before submission.

## Owner input needed

- Support contact details. The localized public privacy, support, and marketing URLs are now uploaded for all 17 App Store locales.
- App Review contact name, email, and phone number.
- Copyright holder text for the store listing.
- Confirmation of the app privacy answers. The source currently processes selected photos and videos locally and has no analytics, account, or network SDK. The draft privacy manifest declares no collected data or tracking.
- Age rating and content-rights questionnaire answers.
- The exact features GIFBloom Pro should unlock. The app presents weekly and annual subscriptions plus the lifetime purchase with StoreKit views and checks verified entitlements. The monthly App Store Connect product remains tracked but is not offered in the app interface, and no app features are gated until the Pro benefit scope is confirmed.
- Real App Store screenshots. Existing UI audit images show empty smoke-test screens and are not suitable for the product page. Please provide representative project media or approve creating screenshots from a seeded demo project.
- Release version alignment. The local Xcode project is now `1.0` / build `7`, matching the editable App Store Connect version. Existing uploaded builds remain `1.03` / builds `6` and `7`; a new `1.0` build must be generated and uploaded before submission.

## Still incomplete in App Store Connect

- No App Store screenshots are attached to the `1.0` version.
- Privacy policy, support, and marketing URLs are populated for all 17 App Store locales.
- No age-rating declaration, copyright text, or App Review contact details are set.
- The app version has no build attached.
- App Review screenshots and review notes for the weekly and annual subscriptions have been uploaded to App Store Connect. Both products now report `READY_TO_SUBMIT`. The lifetime purchase still needs App Review screenshots and review information. The monthly product remains tracked but is not shown in the current app purchase flow. The first in-app purchase submission still has to be completed together with a matching app build in App Store Connect. A draft review submission (`38d82b54-457e-4f39-8dcf-8c8db65d6da8`) contains the subscription group plus weekly and annual subscription versions; the app version still needs to be added after the required app metadata and matching build are ready.
- The latest Fastlane snapshot contains prices and availability for all 175 territories for weekly, monthly, annual, and lifetime products. The United States prices are USD 1.99 per week, USD 3.99 per month, USD 29.99 per year, and USD 49.99 for lifetime. The monthly subscription is not enabled for new territories; the weekly and annual subscriptions and lifetime purchase are enabled for new territories. The app's own price is still unset pending owner confirmation.
- Weekly, monthly, annual, and lifetime products have localized display names and descriptions in all 17 app locales. Their localized versions remain in `PREPARE_FOR_SUBMISSION`; the weekly and annual review assets are uploaded and both products report `READY_TO_SUBMIT` in App Store Connect. The app UI now has 760 matching localization keys across all 17 app languages, and the 17 App Store metadata locales pass the field length checks.
- The app settings and App Store listing now link to the live privacy and support pages and the Apple Standard EULA.
- No App Privacy response has been published. Review the data-collection declaration before publishing it.

No build was run and nothing has been submitted for App Review. The local project now targets version `1.0`; a new build must be generated and uploaded before the app version can be added to the review submission.
