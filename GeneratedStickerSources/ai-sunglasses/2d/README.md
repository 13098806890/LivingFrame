# Sunglasses 2D view assets

These transparent PNG views were created with OpenAI ImageGen and are bundled at `Packages/LivingFrameCore/Sources/LivingFrameCore/Resources/GeneratedStickers/AI贴纸/`.

At runtime the 2D sticker selects the nearest authored view for the tracked yaw, then aligns that PNG to the face landmarks. It does not blend two independently illustrated views.

Prompt set:

- Three-quarter: “Create a transparent-background 2D sticker of glossy dark cartoon sunglasses in the same hand-drawn style as the front-view sunglasses sticker, turned about 40 degrees toward the viewer's left. The near lens should read wider than the far lens. Keep the clean white sticker outline and blue lens reflections.”
- Profile: “Create a transparent-background 2D sticker of the same glossy dark cartoon sunglasses in a clean side profile. Show one lens almost edge-on and a single temple arm extending backward. Match the existing hand-drawn sticker style, white outline, dark frame, and blue highlights.”

The existing front-facing `sunglasses.png` remains the zero-yaw view.
