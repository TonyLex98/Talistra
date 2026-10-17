use std::collections::HashMap;
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::atomic::{AtomicI64, Ordering};
use std::sync::{Arc, LazyLock, Mutex};

use djvu_rs::text::{TextZone, TextZoneKind};
use djvu_rs::{Document, Pixmap};
use jni::JNIEnv;
use jni::objects::{JClass, JString};
use jni::sys::{jbyteArray, jint, jintArray, jlong, jlongArray, jstring};

static NEXT_HANDLE: AtomicI64 = AtomicI64::new(1);
static DOCUMENTS: LazyLock<Mutex<HashMap<i64, Arc<Document>>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));

fn document(handle: jlong) -> Result<Arc<Document>, String> {
    DOCUMENTS
        .lock()
        .map_err(|_| "DjVu document registry is unavailable".to_owned())?
        .get(&handle)
        .cloned()
        .ok_or_else(|| "DjVu document is already closed".to_owned())
}

fn throw(env: &mut JNIEnv<'_>, error: impl ToString) {
    let _ = env.throw_new("java/lang/IllegalStateException", error.to_string());
}

fn guarded<T>(operation: impl FnOnce() -> Result<T, String>) -> Result<T, String> {
    catch_unwind(AssertUnwindSafe(operation)).unwrap_or_else(|payload| {
        let detail = payload
            .downcast_ref::<&str>()
            .copied()
            .or_else(|| payload.downcast_ref::<String>().map(String::as_str))
            .unwrap_or("unknown decoder failure");
        Err(format!("DjVu decoder rejected the page: {detail}"))
    })
}

fn encode_png(pixmap: Pixmap) -> Result<Vec<u8>, String> {
    let mut output = Vec::new();
    {
        let mut encoder = png::Encoder::new(&mut output, pixmap.width, pixmap.height);
        encoder.set_color(png::ColorType::Rgba);
        encoder.set_depth(png::BitDepth::Eight);
        // Fast, not the default: the page is shown once and thrown away, and
        // squeezing a multi-megapixel scan with the default compressor took
        // an order of magnitude longer than decoding the DjVu itself (about
        // 500 ms against 60 for a 2400 px page on a desktop, several times
        // that on a phone) — the biggest part of a page turn.
        encoder.set_compression(png::Compression::Fast);
        let mut writer = encoder.write_header().map_err(|e| e.to_string())?;
        writer
            .write_image_data(&pixmap.data)
            .map_err(|e| e.to_string())?;
    }
    Ok(output)
}

fn append_word_zones(zone: &TextZone, output: &mut String) {
    if zone.kind == TextZoneKind::Word && !zone.text.trim().is_empty() {
        let clean_text: String = zone
            .text
            .chars()
            .map(|character| {
                if character.is_control() {
                    ' '
                } else {
                    character
                }
            })
            .collect::<String>()
            .trim()
            .to_owned();
        if !clean_text.is_empty() {
            if !output.is_empty() {
                output.push('\u{001e}');
            }
            output.push_str(&zone.rect.x.to_string());
            output.push('\u{001f}');
            output.push_str(&zone.rect.y.to_string());
            output.push('\u{001f}');
            output.push_str(&zone.rect.width.to_string());
            output.push('\u{001f}');
            output.push_str(&zone.rect.height.to_string());
            output.push('\u{001f}');
            output.push_str(&clean_text);
        }
    }
    for child in &zone.children {
        append_word_zones(child, output);
    }
}

#[unsafe(no_mangle)]
pub extern "system" fn Java_com_talistra_reader_DjvuNative_open(
    mut env: JNIEnv,
    _class: JClass,
    path: JString,
) -> jlongArray {
    let result = guarded(|| -> Result<[jlong; 2], String> {
        let path: String = env.get_string(&path).map_err(|e| e.to_string())?.into();
        let document = Arc::new(Document::open(path).map_err(|e| e.to_string())?);
        let pages = document.page_count();
        if pages == 0 {
            return Err("The DjVu document has no pages".to_owned());
        }
        let handle = NEXT_HANDLE.fetch_add(1, Ordering::Relaxed);
        DOCUMENTS
            .lock()
            .map_err(|_| "DjVu document registry is unavailable".to_owned())?
            .insert(handle, document);
        Ok([handle, pages as jlong])
    });

    match result {
        Ok(values) => match env.new_long_array(values.len() as jint) {
            Ok(array) => {
                if let Err(error) = env.set_long_array_region(&array, 0, &values) {
                    throw(&mut env, error);
                    std::ptr::null_mut()
                } else {
                    array.into_raw()
                }
            }
            Err(error) => {
                throw(&mut env, error);
                std::ptr::null_mut()
            }
        },
        Err(error) => {
            throw(&mut env, error);
            std::ptr::null_mut()
        }
    }
}

#[unsafe(no_mangle)]
pub extern "system" fn Java_com_talistra_reader_DjvuNative_pageInfo(
    mut env: JNIEnv,
    _class: JClass,
    handle: jlong,
    page_index: jint,
) -> jintArray {
    let result = guarded(|| -> Result<[jint; 3], String> {
        let document = document(handle)?;
        let page = document
            .page(page_index.max(0) as usize)
            .map_err(|e| e.to_string())?;
        Ok([
            page.display_width() as jint,
            page.display_height() as jint,
            page.dpi() as jint,
        ])
    });

    match result {
        Ok(values) => match env.new_int_array(values.len() as jint) {
            Ok(array) => {
                if let Err(error) = env.set_int_array_region(&array, 0, &values) {
                    throw(&mut env, error);
                    std::ptr::null_mut()
                } else {
                    array.into_raw()
                }
            }
            Err(error) => {
                throw(&mut env, error);
                std::ptr::null_mut()
            }
        },
        Err(error) => {
            throw(&mut env, error);
            std::ptr::null_mut()
        }
    }
}

#[unsafe(no_mangle)]
pub extern "system" fn Java_com_talistra_reader_DjvuNative_renderPage(
    mut env: JNIEnv,
    _class: JClass,
    handle: jlong,
    page_index: jint,
    width: jint,
    height: jint,
) -> jbyteArray {
    let result = guarded(|| -> Result<Vec<u8>, String> {
        let document = document(handle)?;
        let page = document
            .page(page_index.max(0) as usize)
            .map_err(|e| e.to_string())?;
        let pixmap = page
            .render_to_size(width.max(1) as u32, height.max(1) as u32)
            .map_err(|e| e.to_string())?;
        encode_png(pixmap)
    });

    match result {
        Ok(bytes) => match env.byte_array_from_slice(&bytes) {
            Ok(array) => array.into_raw(),
            Err(error) => {
                throw(&mut env, error);
                std::ptr::null_mut()
            }
        },
        Err(error) => {
            throw(&mut env, error);
            std::ptr::null_mut()
        }
    }
}

#[unsafe(no_mangle)]
pub extern "system" fn Java_com_talistra_reader_DjvuNative_pageText(
    mut env: JNIEnv,
    _class: JClass,
    handle: jlong,
    page_index: jint,
) -> jstring {
    let result = guarded(|| -> Result<Option<String>, String> {
        let document = document(handle)?;
        document
            .page(page_index.max(0) as usize)
            .map_err(|e| e.to_string())?
            .text()
            .map_err(|e| e.to_string())
    });

    match result {
        Ok(Some(text)) => match env.new_string(text) {
            Ok(value) => value.into_raw(),
            Err(error) => {
                throw(&mut env, error);
                std::ptr::null_mut()
            }
        },
        Ok(None) => std::ptr::null_mut(),
        Err(error) => {
            throw(&mut env, error);
            std::ptr::null_mut()
        }
    }
}

#[unsafe(no_mangle)]
pub extern "system" fn Java_com_talistra_reader_DjvuNative_pageWords(
    mut env: JNIEnv,
    _class: JClass,
    handle: jlong,
    page_index: jint,
) -> jstring {
    let result = guarded(|| -> Result<String, String> {
        let document = document(handle)?;
        let page = document
            .page(page_index.max(0) as usize)
            .map_err(|e| e.to_string())?;
        let Some(layer) = page.text_layer().map_err(|e| e.to_string())? else {
            return Ok(String::new());
        };
        let mut output = String::new();
        for zone in &layer.zones {
            append_word_zones(zone, &mut output);
        }
        Ok(output)
    });

    match result {
        Ok(words) => match env.new_string(words) {
            Ok(value) => value.into_raw(),
            Err(error) => {
                throw(&mut env, error);
                std::ptr::null_mut()
            }
        },
        Err(error) => {
            throw(&mut env, error);
            std::ptr::null_mut()
        }
    }
}

#[unsafe(no_mangle)]
pub extern "system" fn Java_com_talistra_reader_DjvuNative_close(
    mut env: JNIEnv,
    _class: JClass,
    handle: jlong,
) {
    match DOCUMENTS.lock() {
        Ok(mut documents) => {
            documents.remove(&handle);
        }
        Err(_) => throw(&mut env, "DjVu document registry is unavailable"),
    }
}
