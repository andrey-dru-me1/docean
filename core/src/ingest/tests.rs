//! Unit tests for the ingestion pipeline and text extractors.
//!
//! These build small **in-memory sample files** and ingest them through a fresh
//! [`SqliteDocumentStore`] rooted at a temp directory.

use std::fs;
use std::path::{Path, PathBuf};

use crate::ingest::text::{classify, extract, Format};
use crate::ingest::{
    FileInfo, IngestError, IngestOption, IngestPipeline, ProgressEvent, VecProgressSink,
};
use crate::storage::{DocumentStore, SqliteDocumentStore};

// ---------------------------------------------------------------------------
// Sample file builders
// ---------------------------------------------------------------------------

/// A minimal single-page PDF with extractable text, built with `lopdf`.
pub fn sample_pdf_bytes() -> Vec<u8> {
    use lopdf::{
        content::{Content, Operation},
        dictionary, Document, Object, Stream,
    };

    let mut doc = Document::with_version("1.5");
    let pages_id = doc.new_object_id();
    let font_id = doc.add_object(dictionary! {
        "Type" => "Font",
        "Subtype" => "Type1",
        "BaseFont" => "Helvetica",
    });
    let resources_id = doc.add_object(dictionary! {
        "Font" => dictionary! {
            "F1" => font_id,
        },
    });
    let content = Content {
        operations: vec![
            Operation::new("BT", vec![]),
            Operation::new("Tf", vec!["F1".into(), 12.into()]),
            Operation::new("Td", vec![72.into(), 720.into()]),
            Operation::new("Tj", vec![Object::string_literal("Hello PDF")]),
            Operation::new("ET", vec![]),
        ],
    };
    let content_id = doc.add_object(Stream::new(dictionary! {}, content.encode().unwrap()));
    let page_id = doc.add_object(dictionary! {
        "Type" => "Page",
        "Parent" => pages_id,
        "Contents" => content_id,
        "Resources" => resources_id,
        "MediaBox" => vec![0.into(), 0.into(), 612.into(), 792.into()],
    });
    let pages = dictionary! {
        "Type" => "Pages",
        "Kids" => vec![page_id.into()],
        "Count" => 1,
    };
    doc.objects.insert(pages_id, Object::Dictionary(pages));
    let catalog_id = doc.add_object(dictionary! {
        "Type" => "Catalog",
        "Pages" => pages_id,
    });
    doc.trailer.set("Root", catalog_id);

    let mut bytes = Vec::new();
    doc.save_to(&mut bytes).unwrap();
    bytes
}

/// A `.docx`-shaped ZIP with a minimal `word/document.xml`.
pub fn sample_docx_bytes() -> Vec<u8> {
    let doc_xml = br#"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:body>
    <w:p><w:r><w:t>Hello</w:t></w:r><w:r><w:t xml:space="preserve"> Docx</w:t></w:r></w:p>
    <w:p><w:r><w:t>Second paragraph</w:t></w:r></w:p>
  </w:body>
</w:document>"#;
    build_zip(&[("word/document.xml", doc_xml.to_vec())])
}

/// A `.odt`-shaped ZIP with a minimal `content.xml`.
pub fn sample_odt_bytes() -> Vec<u8> {
    let content_xml = br#"<?xml version="1.0" encoding="UTF-8"?>
<office:document-content xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0">
  <office:body>
    <office:text>
      <text:p>Hello</text:p>
      <text:p>ODF world</text:p>
    </office:text>
  </office:body>
</office:document-content>"#;
    build_zip(&[("content.xml", content_xml.to_vec())])
}

/// Build a minimal ZIP archive in memory.
fn temp_root(tag: &str) -> PathBuf {
    let mut p = std::env::temp_dir();
    p.push(format!(
        "docer-ingest-{tag}-{}-{}",
        std::process::id(),
        rand_token()
    ));
    fs::create_dir_all(&p).unwrap();
    p
}

fn rand_token() -> u128 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos()
}

fn fresh_store(tag: &str) -> SqliteDocumentStore {
    SqliteDocumentStore::open(temp_root(tag)).unwrap()
}

// ---------------------------------------------------------------------------
// Format classification
// ---------------------------------------------------------------------------

#[test]
fn classifies_common_extensions() {
    assert_eq!(classify("pdf"), Format::Pdf);
    assert_eq!(classify("txt"), Format::PlainText);
    assert_eq!(classify("md"), Format::Markdown);
    assert_eq!(classify("docx"), Format::Docx);
    assert_eq!(classify("odt"), Format::Odt);
    assert_eq!(classify("eml"), Format::Email);
    assert_eq!(classify("png"), Format::Image);
    assert_eq!(classify("doc"), Format::Unsupported);
    assert_eq!(classify("weirdformat"), Format::Unknown);
}

// ---------------------------------------------------------------------------
// Text extractors
// ---------------------------------------------------------------------------

#[test]
fn extracts_plain_text() {
    let e = extract("txt", b"hello world\n").unwrap();
    assert_eq!(e.text, "hello world");
    assert_eq!(e.source, "plain");
}

#[test]
fn extracts_utf16_text() {
    let mut utf16: Vec<u8> = vec![0xFF, 0xFE];
    for unit in "hello".encode_utf16() {
        utf16.extend_from_slice(&unit.to_le_bytes());
    }
    let e = extract("txt", &utf16).unwrap();
    assert_eq!(e.text, "hello");
}

#[test]
fn extracts_markdown() {
    let e = extract("md", b"# Title\n\nSome **text** here.\n").unwrap();
    assert_eq!(e.text, "# Title\n\nSome **text** here.");
    assert_eq!(e.source, "markdown");
}

#[test]
fn extracts_pdf_text() {
    let e = extract("pdf", &sample_pdf_bytes()).unwrap();
    assert!(
        e.text.contains("Hello PDF"),
        "extracted text was: {:?}",
        e.text
    );
    assert_eq!(e.source, "pdf");
}

#[test]
fn extracts_docx_text() {
    let e = extract("docx", &sample_docx_bytes()).unwrap();
    assert!(e.text.contains("Hello Docx"), "got {:?}", e.text);
    assert!(e.text.contains("Second paragraph"));
    assert_eq!(e.source, "docx");
}

#[test]
fn extracts_odt_text() {
    let e = extract("odt", &sample_odt_bytes()).unwrap();
    assert!(e.text.contains("Hello"), "got {:?}", e.text);
    assert!(e.text.contains("ODF world"));
    assert_eq!(e.source, "odt");
}

#[test]
fn extracts_email_headers_and_body() {
    let bytes = b"From: Alice <alice@example.com>\r\nTo: Bob <bob@example.com>\r\nSubject: Hello There\r\nDate: Mon, 1 Jan 2024 10:00:00 +0000\r\n\r\nThis is the email body.";
    let e = extract("eml", bytes).unwrap();
    assert!(e.text.contains("Subject: Hello There"), "got {:?}", e.text);
    assert!(e.text.contains("From: Alice"));
    assert!(e.text.contains("This is the email body."));
    assert_eq!(e.source, "email");
}

#[test]
fn images_without_ocr_have_no_text_layer() {
    let e = extract("png", b"not a real png").unwrap();
    assert!(e.text.is_empty());
    assert_eq!(e.source, "none");
}

#[test]
fn unsupported_extension_returns_error() {
    let e = extract("doc", b"some legacy format");
    assert!(matches!(e, Err(IngestError::Unsupported(_))));
}
pub fn build_zip(entries: &[(&str, Vec<u8>)]) -> Vec<u8> {
    use std::io::{Cursor, Write};
    let mut cursor = Cursor::new(Vec::new());
    {
        let mut w = zip::ZipWriter::new(&mut cursor);
        let options: zip::write::SimpleFileOptions = zip::write::SimpleFileOptions::default()
            .compression_method(zip::CompressionMethod::Deflated);
        for (name, data) in entries {
            w.start_file(*name, options).unwrap();
            w.write_all(data).unwrap();
        }
        w.finish().unwrap();
    }
    cursor.into_inner()
}

/// Write `bytes` to `<root>/<name>` and return the path.
pub fn write_sample(root: &Path, name: &str, bytes: &[u8]) -> PathBuf {
    let path = root.join(name);
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).unwrap();
    }
    fs::write(&path, bytes).unwrap();
    path
}

// ---------------------------------------------------------------------------
// Pipeline vs. store
// ---------------------------------------------------------------------------

#[test]
fn ingests_plain_text_file_with_metadata() {
    let mut store = fresh_store("plain");
    let root = temp_root("plain-src");
    let path = write_sample(&root, "note.txt", b"hello ingestion\nsecond line\n");

    let mut progress = VecProgressSink::new();
    let ids = IngestPipeline::new()
        .ingest(
            &mut store,
            &[FileInfo::from_path(&path).unwrap()],
            &IngestOption::default(),
            Some(&mut progress),
        )
        .unwrap();

    assert_eq!(ids.len(), 1);
    let id = &ids[0];
    let doc = store.get(id).unwrap();

    assert_eq!(doc.title, "note");
    assert_eq!(doc.mime_type, "text/plain");
    assert_eq!(doc.size_bytes, 28);
    assert_eq!(doc.checksum_sha256, *id);
    assert_eq!(doc.tags.len(), 0);
    assert!(doc.created_at_ms > 0);
    assert!(doc.updated_at_ms > 0);
    assert_eq!(
        doc.extra.get("original_name").map(String::as_str),
        Some("note.txt")
    );
    assert_eq!(
        doc.extra.get("extractor").map(String::as_str),
        Some("plain")
    );

    // Bytes landed in the content-addressed blob store.
    assert!(store.blobs().contains(id));

    // Extracted text is stored.
    let content = store.get_content(id).unwrap().unwrap();
    assert_eq!(content.text, "hello ingestion\nsecond line");
    assert_eq!(content.source, "plain");

    // Progress events: Processing -> Extracting -> Completed, no failed.
    let kinds: Vec<&str> = progress
        .events
        .iter()
        .map(|e| match e {
            ProgressEvent::Processing { .. } => "processing",
            ProgressEvent::Extracting { .. } => "extracting",
            ProgressEvent::Completed { .. } => "completed",
            ProgressEvent::Failed { .. } => "failed",
            ProgressEvent::Skipped { .. } => "skipped",
        })
        .collect();
    assert!(kinds.contains(&"processing"));
    assert!(kinds.contains(&"extracting"));
    assert!(kinds.contains(&"completed"));
    assert!(!kinds.contains(&"failed"));

    let _ = fs::remove_dir_all(&root);
    let _ = store;
}

#[test]
fn deduplicates_identical_bytes_into_one_document() {
    let mut store = fresh_store("dedupe");
    let root = temp_root("dedupe-src");

    let p1 = write_sample(&root, "a.txt", b"same content");
    let p2 = write_sample(&root, "b.txt", b"same content");

    let ids = IngestPipeline::new()
        .ingest(
            &mut store,
            &[
                FileInfo::from_path(&p1).unwrap(),
                FileInfo::from_path(&p2).unwrap(),
            ],
            &IngestOption::default(),
            None,
        )
        .unwrap();

    // Same SHA-256 because content is identical (content addressing).
    assert_eq!(ids[0], ids[1]);
    let doc = store.get(&ids[0]).unwrap();
    // Both files map to the same document id (the content address); the second
    // write upserts metadata title to "b" because it is the same physical doc.
    assert_eq!(doc.title, "b");
    assert!(store.blobs().contains(&ids[0]));

    let _ = fs::remove_dir_all(&root);
}

#[test]
fn skip_existing_does_not_rewrite_duplicate() {
    let mut store = fresh_store("skip");
    let root = temp_root("skip-src");

    let p1 = write_sample(&root, "first.txt", b"payload");
    let p2 = write_sample(&root, "second.txt", b"payload");

    IngestPipeline::new()
        .ingest(
            &mut store,
            &[FileInfo::from_path(&p1).unwrap()],
            &IngestOption::default(),
            None,
        )
        .unwrap();

    let mut progress = VecProgressSink::new();
    let ids = IngestPipeline::new()
        .ingest(
            &mut store,
            &[FileInfo::from_path(&p2).unwrap()],
            &IngestOption {
                skip_existing: true,
                ..Default::default()
            },
            Some(&mut progress),
        )
        .unwrap();
    assert_eq!(ids.len(), 1);
    // Skipped: the only events are Processing then Skipped — no Completed.
    assert!(!progress
        .events
        .iter()
        .any(|e| matches!(e, ProgressEvent::Completed { .. })));
    assert!(progress
        .events
        .iter()
        .any(|e| matches!(e, ProgressEvent::Skipped { .. })));
    assert_eq!(
        progress
            .events
            .iter()
            .filter(|e| matches!(e, ProgressEvent::Skipped { .. }))
            .count(),
        1
    );

    let _ = fs::remove_dir_all(&root);
}

#[test]
fn ingested_document_roundtrips_through_query() {
    let mut store = fresh_store("query");
    let root = temp_root("query-src");
    let path = write_sample(&root, "report.md", b"# Report\n\nBody text.");

    let ids = IngestPipeline::new()
        .ingest(
            &mut store,
            &[FileInfo::from_path(&path).unwrap()],
            &IngestOption::default(),
            None,
        )
        .unwrap();

    let q = store
        .query(&crate::storage::DocumentQuery {
            kind: Some(crate::domain::NodeKind::Document),
            ..Default::default()
        })
        .unwrap();
    assert_eq!(q.len(), 1);
    assert_eq!(q[0].id, ids[0]);

    let _ = fs::remove_dir_all(&root);
}

#[test]
fn unsupported_file_produces_failed_event() {
    let mut store = fresh_store("unsupported");
    let root = temp_root("unsupported-src");
    let path = write_sample(&root, "legacy.doc", b"%legacy");

    let mut progress = VecProgressSink::new();
    let result = IngestPipeline::new().ingest(
        &mut store,
        &[FileInfo::from_path(&path).unwrap()],
        &IngestOption::default(),
        Some(&mut progress),
    );

    assert!(matches!(result, Err(IngestError::Unsupported(_))));
    assert!(progress
        .events
        .iter()
        .any(|e| matches!(e, ProgressEvent::Failed { .. })));
    assert_eq!(store.query(&Default::default()).unwrap().len(), 0);

    let _ = fs::remove_dir_all(&root);
}
#[test]
fn ingest_missing_file_returns_io_error() {
    let mut store = fresh_store("missing");
    let missing = temp_root("missing-src").join("nope.txt");

    let result = IngestPipeline::new().ingest(
        &mut store,
        &[FileInfo {
            path: missing.clone(),
            size: 0,
            modified_ms: 0,
            created_ms: 0,
        }],
        &IngestOption::default(),
        None,
    );
    assert!(matches!(result, Err(IngestError::Io(_))));
    let _ = fs::remove_dir_all(missing.parent().unwrap());
}

#[test]
fn destination_path_is_recorded_in_extra() {
    let mut store = fresh_store("dest");
    let root = temp_root("dest-src");
    let path = write_sample(&root, "doc.txt", b"x");

    let opts = IngestOption {
        destination_path: Some("/inbox".to_owned()),
        ..Default::default()
    };
    let ids = IngestPipeline::new()
        .ingest(
            &mut store,
            &[FileInfo::from_path(&path).unwrap()],
            &opts,
            None,
        )
        .unwrap();

    let doc = store.get(&ids[0]).unwrap();
    assert_eq!(
        doc.extra.get("destination_path").map(String::as_str),
        Some("/inbox")
    );

    let _ = fs::remove_dir_all(&root);
}

#[test]
fn title_override_applies_to_first_file() {
    let mut store = fresh_store("title");
    let root = temp_root("title-src");
    let p1 = write_sample(&root, "one.txt", b"1");
    let p2 = write_sample(&root, "two.txt", b"2");

    let opts = IngestOption {
        title_override: Some("Renamed".to_owned()),
        ..Default::default()
    };
    let ids = IngestPipeline::new()
        .ingest(
            &mut store,
            &[
                FileInfo::from_path(&p1).unwrap(),
                FileInfo::from_path(&p2).unwrap(),
            ],
            &opts,
            None,
        )
        .unwrap();

    assert_eq!(store.get(&ids[0]).unwrap().title, "Renamed");
    assert_eq!(store.get(&ids[1]).unwrap().title, "two");

    let _ = fs::remove_dir_all(&root);
}

#[test]
fn ingest_one_wrapper_returns_single_id() {
    let mut store = fresh_store("one");
    let root = temp_root("one-src");
    let path = write_sample(&root, "solo.txt", b"only one");

    let id = IngestPipeline::new()
        .ingest_one(&mut store, &path, &IngestOption::default(), None)
        .unwrap();

    assert_eq!(store.get(&id).unwrap().title, "solo");

    let _ = fs::remove_dir_all(&root);
}
