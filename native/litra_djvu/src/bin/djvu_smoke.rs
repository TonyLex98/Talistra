use std::path::Path;

use djvu_rs::Document;
use djvu_rs::text::{TextZone, TextZoneKind};

fn count_words(zone: &TextZone) -> usize {
    usize::from(zone.kind == TextZoneKind::Word && !zone.text.trim().is_empty())
        + zone.children.iter().map(count_words).sum::<usize>()
}

fn main() {
    let paths: Vec<_> = std::env::args_os().skip(1).collect();
    assert!(!paths.is_empty(), "pass at least one DjVu file");
    for path in paths {
        let document = Document::open(&path).expect("open DjVu");
        assert!(document.page_count() > 0, "DjVu must contain pages");
        let mut word_count = 0;
        let indices = [0, document.page_count() - 1];
        for index in indices {
            let page = document.page(index).expect("read page");
            let width = 720;
            let height = ((width as f64 * page.display_height() as f64)
                / page.display_width().max(1) as f64)
                .round()
                .max(1.0) as u32;
            let pixmap = page
                .render_to_size(width, height)
                .expect("render DjVu page");
            assert_eq!(pixmap.width, width);
            assert_eq!(pixmap.height, height);
            assert_eq!(
                pixmap.data.len(),
                (width * height * 4) as usize,
                "RGBA buffer size",
            );
            if let Some(layer) = page.text_layer().expect("decode optional text layer") {
                word_count += layer.zones.iter().map(count_words).sum::<usize>();
            }
        }
        println!(
            "{}: {} pages, first and last rendered, {} positioned words",
            Path::new(&path).display(),
            document.page_count(),
            word_count,
        );
    }
}
