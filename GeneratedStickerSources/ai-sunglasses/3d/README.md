# Amethyst sunglasses 3D view source

`amethyst-sunglasses.scn` is a procedural SceneKit model. The Swift generator renders it to three transparent PNG views, which the app then selects and cross-fades using the tracked face yaw. The app does not run a 3D renderer while editing or exporting; it uses these baked 2D views, matching the proposed model-to-sprite workflow.

Regenerate the model and source PNGs on macOS with:

```sh
swift GeneratedStickerSources/ai-sunglasses/3d/RenderSunglassesViews.swift GeneratedStickerSources/ai-sunglasses/3d
```

The PNGs bundled by the app are copied to `Packages/LivingFrameCore/Sources/LivingFrameCore/Resources/GeneratedStickers/AI贴纸/`.
