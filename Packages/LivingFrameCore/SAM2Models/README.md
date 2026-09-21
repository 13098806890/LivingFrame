# SAM 2.1 Tiny Core ML

These three model packages are the float16 Core ML conversion published by
Apple at [apple/coreml-sam2.1-tiny](https://huggingface.co/apple/coreml-sam2.1-tiny).

The model is released under Apache-2.0. The directory names intentionally have
no extension: SwiftPM resource bundles otherwise treat `.mlpackage` as nested
code bundles during simulator signing. The package contents remain unchanged
and are compiled at runtime by `SAM2Segmenter`.
