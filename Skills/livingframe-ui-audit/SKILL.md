---
name: livingframe-ui-audit
description: Run LivingFrame in an iOS Simulator, exercise core editing, playback, save, reopen, export, and settings flows, collect deterministic screenshots and logs, visually diagnose UI, localization, accessibility, and launch problems, and write a reproducible Chinese HTML audit report. Use when asked to inspect, audit, screenshot, functionally test, or troubleshoot the app in Simulator; do not use for hardware-only media export validation.
---

# LivingFrame UI Audit

Run a repeatable Simulator audit, inspect its evidence, and report only issues supported by screenshots, logs, accessibility hierarchy, or source code.

## Run the audit

From the repository root, execute:

```bash
Scripts/UIAudit/run_ui_audit.sh
```

The default `full` profile first runs a deterministic functional workflow, then captures the four main tabs in Simplified Chinese, English, Arabic, English dark appearance, and English accessibility XXXL text. The functional workflow uses an explicitly requested Debug-only project fixture and real App APIs/UI to exercise:

- Media persistence and canvas rendering with a generated background image.
- Dynamic sticker playback, pause, and full-screen preview.
- Canvas background, text editing, and sticker insertion controls.
- Manual save, Works listing, and reopening the saved composition.
- Real GIF encoding through the export screen (without writing to Photos).
- Theme and media-quality settings, including relaunch persistence.

For a quick launch and navigation check that skips this workflow, use:

```bash
UI_AUDIT_PROFILE=smoke Scripts/UIAudit/run_ui_audit.sh
```

To iterate on only the core feature workflow, use:

```bash
UI_AUDIT_PROFILE=functional Scripts/UIAudit/run_ui_audit.sh
```

Set `UI_AUDIT_DEVICE` to an exact available Simulator name when the default device is absent. Do not erase a whole Simulator; the runner uninstalls only `com.livingframe.app` before testing.

Running Xcode or Simulator services may require user approval in a restricted environment. Ask only when the command actually requires that approval.

## Inspect the evidence

Read `Artifacts/UIAudit/latest.txt` to find the latest run. Inspect:

- `metadata.env` for device, profile, and exit status.
- `xcodebuild.log` for build, launch, assertion, crash, and timeout failures.
- `app.log` for runtime faults from the app process.
- `attachments/functional/normalized-manifest.json` and its ordered `functional--NN-*` PNGs for feature execution evidence.
- Other `attachments/*/normalized-manifest.json` files and every relevant PNG. Use the image inspection tool at original detail when text or pixel alignment matters. Screenshot filenames encode profile, page, state, and scroll position.
- Accessibility hierarchy attachments when a control is missing, mislabeled, duplicated, or unreachable.

Read the functional screenshots in numeric order and verify each expected state transition instead of treating a passing assertion as sufficient. Compare screenshots across profiles. Check safe-area overlap, clipping, truncation, off-screen controls, unusable density, RTL ordering, untranslated text, broken empty states, illegible contrast, unexpected blank regions, and whether requested appearance or text-size settings took effect. Treat Simulator-incompatible HEVC-alpha, system Photos-picker realism, saving into the real Photos library, Widget App Group behavior, and on-device Vision performance as coverage gaps rather than UI failures.

## Report

Write `report.html` inside the run directory. Do not create a Markdown report. The report must be a self-contained Simplified Chinese HTML document that works offline without external fonts, scripts, stylesheets, or network assets. Use relative paths to embed the relevant audit PNGs directly beside each finding, with concise Chinese captions; clicking an image should open the original-resolution file. Make the layout responsive so it remains readable on desktop and mobile.

Start with run status and coverage. Then list findings by severity:

- P0: crash, data loss, or app cannot launch.
- P1: a primary flow is blocked or a required control cannot be reached.
- P2: visible clipping, overlap, localization/RTL failure, major accessibility problem, or misleading state.
- P3: polish issue with a concrete visual impact.

For every finding include the affected profile, embedded screenshots, observable evidence, concise reproduction steps, and the most likely source location after checking the code. Place screenshots immediately after the claim they support instead of collecting them into a detached gallery. Separate confirmed findings from coverage gaps and hypotheses. If no issue is confirmed, say so and state exactly what was covered.

When the user asks only for diagnosis, do not modify product code. When asked to fix issues, preserve unrelated working-tree changes, implement the scoped fixes, and rerun at least the affected profile before claiming success.
