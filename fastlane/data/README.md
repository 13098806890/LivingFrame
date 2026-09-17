# Versioned App Store Connect data

`1.0/` is a full baseline captured from the current App Store Connect draft on 2026-09-17. It includes every supported localization and the current territory price rows for both purchase products.

For later versions, retain the baseline and record only changes under a new version directory. Use ordinary field-level JSON changes for app settings and replace only the affected locale files or territory entries for product changes. Do not create a new version directory until that App Store version is actually being prepared.

The purchase price JSON files are snapshots, not instructions to change a price. Review any proposed price change first; price increases and territory equalization can have customer and financial effects.
