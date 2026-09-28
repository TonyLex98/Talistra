# Release (R8) keep rules for TransReade.
#
# google_mlkit_text_recognition references script-specific recognizers
# (Chinese/Japanese/Korean/Devanagari) that are NOT bundled — only the Latin
# recognizer ships with the app. The plugin touches them reflectively, so
# tell R8 not to fail on the missing optional classes. Suggested by AGP
# itself (build/app/outputs/mapping/release/missing_rules.txt).
-dontwarn com.google.mlkit.vision.text.chinese.ChineseTextRecognizerOptions
-dontwarn com.google.mlkit.vision.text.chinese.ChineseTextRecognizerOptions$Builder
-dontwarn com.google.mlkit.vision.text.devanagari.DevanagariTextRecognizerOptions
-dontwarn com.google.mlkit.vision.text.devanagari.DevanagariTextRecognizerOptions$Builder
-dontwarn com.google.mlkit.vision.text.japanese.JapaneseTextRecognizerOptions
-dontwarn com.google.mlkit.vision.text.japanese.JapaneseTextRecognizerOptions$Builder
-dontwarn com.google.mlkit.vision.text.korean.KoreanTextRecognizerOptions
-dontwarn com.google.mlkit.vision.text.korean.KoreanTextRecognizerOptions$Builder
