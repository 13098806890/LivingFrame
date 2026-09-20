fastlane documentation
----

# Installation

Make sure you have the latest version of the Xcode command line tools installed:

```sh
xcode-select --install
```

For _fastlane_ installation instructions, see [Installing _fastlane_](https://docs.fastlane.tools/#installing-fastlane)

# Available Actions

## iOS

### ios upload_metadata

```sh
[bundle exec] fastlane ios upload_metadata
```

Upload localized App Store listing metadata for a store version (does not submit for review)

### ios upload_screenshots

```sh
[bundle exec] fastlane ios upload_screenshots
```

Upload App Store screenshots for a store version (does not submit for review)

### ios upload_build

```sh
[bundle exec] fastlane ios upload_build
```

Upload a built IPA to App Store Connect without submitting it for review

### ios set_app_price

```sh
[bundle exec] fastlane ios set_app_price
```

Set the app's App Store price using Fastlane's price tier support; requires an explicit confirmation

### ios create_subscription_products

```sh
[bundle exec] fastlane ios create_subscription_products
```

Create or synchronize the weekly and annual subscription metadata from the tracked Fastlane data

### ios sync_purchase_pricing

```sh
[bundle exec] fastlane ios sync_purchase_pricing
```

Sync App Store Connect price schedules and territory availability into Fastlane data

### ios download_store_metadata

```sh
[bundle exec] fastlane ios download_store_metadata
```

Download App Store Connect metadata to the selected local version folder

----

This README.md is auto-generated and will be re-generated every time [_fastlane_](https://fastlane.tools) is run.

More information about _fastlane_ can be found on [fastlane.tools](https://fastlane.tools).

The documentation of _fastlane_ can be found on [docs.fastlane.tools](https://docs.fastlane.tools).
