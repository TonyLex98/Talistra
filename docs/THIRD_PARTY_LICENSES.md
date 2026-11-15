# Third-party licenses

Talistra's own code is under the MIT license (see [LICENSE](../LICENSE)). The app also uses the
components below, each under its own license.

## Syncfusion Flutter PDF — not open source

[`syncfusion_flutter_pdf`](https://pub.dev/packages/syncfusion_flutter_pdf) extracts PDF text and
outlines, reads page rotation, unlocks password-protected files and turns images into PDF pages. It is part of Syncfusion Essential Studio and is **not** under an open-source
license: using it requires either the free
[Syncfusion Community License](https://www.syncfusion.com/products/communitylicense) (individuals
and companies with less than USD 1 million in annual revenue and fewer than five developers) or a
commercial license. Anyone who builds or ships this app must hold one of these licenses. Terms:
https://www.syncfusion.com/content/downloads/syncfusion_license.pdf

## Google ML Kit

Translation and text recognition run on the device through Google ML Kit
([`google_mlkit_translation`](https://pub.dev/packages/google_mlkit_translation),
[`google_mlkit_text_recognition`](https://pub.dev/packages/google_mlkit_text_recognition); the
Flutter plugins are MIT). The ML Kit SDKs and the downloaded language models are subject to the
[ML Kit Terms](https://developers.google.com/ml-kit/terms).

## Fonts — SIL Open Font License 1.1

EB Garamond, Inter, Literata, Lora, Noto Serif and Source Serif 4 in `assets/fonts`. Copyright
lines and the license text: [assets/fonts/OFL.txt](../assets/fonts/OFL.txt).

## Rust

The DjVu decoder `native/litra_djvu` (MIT) is built on
[`djvu-rs`](https://crates.io/crates/djvu-rs) (MIT), [`jni`](https://crates.io/crates/jni)
(MIT / Apache-2.0) and [`png`](https://crates.io/crates/png) (MIT / Apache-2.0). The full
djvu-rs license is at the end of this file.

## Dart packages

| Package | License |
| --- | --- |
| archive, cupertino_icons, excel2003, file_picker, flutter_tts, pdfx, provider, xml | MIT |
| intl, path, path_provider, share_plus, shared_preferences, url_launcher | BSD-3-Clause |

Flutter itself is under the BSD-3-Clause license.

## djvu-rs 0.27.0

Talistra's DjVu bridge uses the pure-Rust `djvu-rs` codec, a clean-room
implementation based on the public DjVu v3 specification. It contains no
DjVuLibre or other GPL code.

MIT License

Copyright (c) 2026 Lev Matyushkin

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
