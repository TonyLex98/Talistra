use std::path::Path;

use djvu_rs::Document;

fn main() {
    let paths: Vec<_> = std::env::args_os().skip(1).collect();
    assert!(!paths.is_empty(), "pass at least one DjVu file");
    for path in paths {
        let document = Document::open(&path).expect("open DjVu");
        assert!(document.page_count() > 0, "DjVu must contain pages");
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
            let _ = page.text().expect("decode optional text layer");
        }
        println!(
            "{}: {} pages, first and last rendered",
            Path::new(&path).display(),
            document.page_count(),
        );
    }
}
