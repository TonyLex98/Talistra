# Litra DjVu engine

Litra renders DjVu through its own JNI bridge in `native/litra_djvu`. The
bridge and its public API are MIT licensed. Its codec dependency is the
clean-room, MIT-licensed `djvu-rs`; no DjVuLibre or GPL binary is linked into
the application.

The checked-in Android libraries cover `arm64-v8a`, `armeabi-v7a`, and
`x86_64`. To rebuild them, install Rust, `cargo-ndk`, the three Android Rust
targets, and Android NDK 27, then run from `native/litra_djvu`:

```powershell
$env:ANDROID_NDK_HOME = "$env:LOCALAPPDATA\Android\sdk\ndk\27.0.12077973"
cargo ndk -t arm64-v8a -t armeabi-v7a -t x86_64 -P 24 `
  -o ../../android/app/src/main/jniLibs build --release
```

`djvu-rs` also declares a `cdylib`, so `cargo-ndk` may copy hashed
`libdjvu_rs-*.so` files beside `liblitra_djvu.so`. Litra statically links the
Rust dependency and only needs `liblitra_djvu.so`; remove the hashed duplicate
libraries before packaging.

For a desktop codec smoke test:

```powershell
cargo run --release --bin djvu_smoke -- first.djvu second.djvu
```
