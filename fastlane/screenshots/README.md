# App Store screenshots

Place actual App Store screenshots under `fastlane/screenshots/<store-version>/<App Store locale>/`. Keep screenshot files directly in each locale directory so Deliver can identify them. The upload lane uses this path and refuses to run while the version directory is absent.

The `1.03` screenshot set contains five generated iPhone product screenshots for every App Store locale. `zh-Hans` and `zh-Hant` use the Chinese source set; all other locales use the English source set. The images are normalized to `1284x2778` for `APP_IPHONE_65`. The existing English iPad Pro sets are retained in `1.03/en-US`.

The new source images are kept in `/Users/doxie/Desktop/GIFBloom/app-store-drafts`. They are `853x1844` originals and were resized to `1284x2778` in the tracked screenshot set; the originals were not modified. The iPad source images are `2420x1668` and target the 11-inch iPad set. For the 13-inch set, they were proportionally fitted into a `2752x2064` canvas with a matching light background extension; the originals were not modified.
