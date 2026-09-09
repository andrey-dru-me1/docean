//! Text extraction for the document formats docean ingests.
//!
//! Each extractor takes the raw file bytes and returns a [`ExtractedText`]:
//! the plain-text body plus a short extractor identifier (stored as
//! `Content.source`). Extractors must never panic on malformed input — they
//! return `Ok("")` / `IngestError::Unsupported` and let the pipeline record a
//! document without a text layer.
//!
//! ## OCR (`cfg(feature = "ocr")`)
//!
//! The optional `tesseract` backend is behind the `ocr` cargo feature because
//! `tesseract-sys` needs a native Tesseract/Leptonica build dependency. Without
//! the feature, image extraction returns an empty body with source `"none"` so
//! the pipeline still ingests the file and its metadata.

use anyhow::Context;
use std::io::Read;

use crate::ingest::IngestError;

/// The outcome of a text-extraction pass.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ExtractedText {
    /// The plain-text content of the file (may be empty).
    pub text: String,
    /// Short extractor identifier: `"pdf"`, `"plain"`, `"markdown"`, `"docx"`,
    /// `"odt"`, `"email"`, `"ocr"`, or `"none"`.
    pub source: &'static str,
}

/// The file-kind group an extension maps to.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Format {
    Pdf,
    PlainText,
    Markdown,
    Docx,
    Odt,
    Email,
    Image,
    Unsupported,
    Unknown,
}

/// Classify a file by its lowercase, dot-stripped extension.
pub fn classify(ext: &str) -> Format {
    match ext {
        "pdf" => Format::Pdf,
        "txt" | "text" | "log" | "csv" | "tsv" | "json" | "xml" | "yaml" | "yml" | "rtf" => {
            Format::PlainText
        }
        "md" | "markdown" => Format::Markdown,
        "docx" | "docm" | "dotx" | "dotm" => Format::Docx,
        "odt" | "ott" => Format::Odt,
        "eml" | "msg" => Format::Email,
        "png" | "jpg" | "jpeg" | "gif" | "bmp" | "tiff" | "tif" | "heic" | "webp" => Format::Image,
        "doc" | "xls" | "xlsx" | "ppt" | "pptx" | "odp" | "ods" => Format::Unsupported,
        "" => Format::Unknown,
        _ => Format::Unknown,
    }
}

/// Extract the plain-text body of `bytes`, guessing the format from `ext`.
pub fn extract(ext: &str, bytes: &[u8]) -> Result<ExtractedText, IngestError> {
    match classify(ext) {
        Format::Pdf => extract_pdf(bytes),
        Format::PlainText => extract_plain(bytes),
        Format::Markdown => extract_markdown(bytes),
        Format::Docx => extract_docx(bytes),
        Format::Odt => extract_odt(bytes),
        Format::Email => extract_email(bytes),
        Format::Image => extract_image(bytes),
        Format::Unsupported => Err(IngestError::Unsupported(format!(".{ext}"))),
        Format::Unknown => extract_plain(bytes),
    }
}

/// Extract the text layer of a PDF.
///
/// `pdf-extract` is a pure-Rust (lopdf-based) extractor; scanned/image-only PDFs
/// yield an empty string here — OCR of those is a future enhancement.
pub fn extract_pdf(bytes: &[u8]) -> Result<ExtractedText, IngestError> {
    let text = pdf_extract::extract_text_from_mem(bytes)
        .context("pdf text extraction failed")
        .map_err(IngestError::Extract)?;
    Ok(ExtractedText {
        text: normalize(text),
        source: "pdf",
    })
}

/// Extract a plain-text file. Tolerates UTF-8, UTF-16-with-BOM, and Latin-1.
pub fn extract_plain(bytes: &[u8]) -> Result<ExtractedText, IngestError> {
    let text = decode_text(bytes);
    Ok(ExtractedText {
        text: normalize(text),
        source: "plain",
    })
}

/// Extract a Markdown file: the plain text body (Markdown syntax is preserved
/// as-is; rendering/normalization is a later concern).
pub fn extract_markdown(bytes: &[u8]) -> Result<ExtractedText, IngestError> {
    Ok(ExtractedText {
        text: normalize(decode_text(bytes)),
        source: "markdown",
    })
}

/// Extract the text from a `.docx`-family OOXML archive.
///
/// Reads `word/document.xml` (or the first `<w:body>` it finds) and concatenates
/// `<w:t>` runs, separating paragraphs with newlines.
pub fn extract_docx(bytes: &[u8]) -> Result<ExtractedText, IngestError> {
    let xml = read_zip_entry(bytes, &["word/document.xml"])?;
    let text = xml_wtext(&xml);
    Ok(ExtractedText {
        text: normalize(text),
        source: "docx",
    })
}

/// Extract the text from an ODF text document (`content.xml`).
///
/// Concatenates `<text:p>` paragraphs: inline runs are picked up from all
/// descendants plus the element's own text, preserving whitespace.
pub fn extract_odt(bytes: &[u8]) -> Result<ExtractedText, IngestError> {
    let xml = read_zip_entry(bytes, &["content.xml"])?;
    let text = odt_paragraphs(&xml);
    Ok(ExtractedText {
        text: normalize(text),
        source: "odt",
    })
}

/// Extract a human-readable body from an email file (`.eml` / `.msg`).
///
/// Uses `mailparse` for RFC 5322 / MIME. Only text parts are kept — attachments
/// (images, application/*, etc.) are skipped; text/plain wins over text/html
/// when both are present, and `text/html` is stripped of tags.
pub fn extract_email(bytes: &[u8]) -> Result<ExtractedText, IngestError> {
    use mailparse::{parse_mail, MailHeaderMap as _};

    let parsed = parse_mail(bytes)
        .context("email parse failed")
        .map_err(IngestError::Extract)?;

    let headers = &parsed.headers;
    let subject = headers.get_first_value("Subject").unwrap_or_default();
    let from = headers.get_first_value("From").unwrap_or_default();
    let to = headers.get_first_value("To").unwrap_or_default();
    let date = headers.get_first_value("Date").unwrap_or_default();

    let mut parts_body: Vec<&mailparse::ParsedMail> = Vec::new();
    if parsed.subparts.is_empty() {
        // A single-part message: the body lives on the root.
        parts_body.push(&parsed);
    } else {
        parts_body.extend(parsed.subparts.iter());
    }
    let body = collect_text_parts(&parts_body);

    let mut out = String::new();
    if !subject.is_empty() {
        out.push_str(&format!("Subject: {subject}\n"));
    }
    if !from.is_empty() {
        out.push_str(&format!("From: {from}\n"));
    }
    if !to.is_empty() {
        out.push_str(&format!("To: {to}\n"));
    }
    if !date.is_empty() {
        out.push_str(&format!("Date: {date}\n"));
    }
    out.push('\n');
    out.push_str(&body);

    Ok(ExtractedText {
        text: normalize(out),
        source: "email",
    })
}

/// Extract text from an image via OCR.
///
/// The `tesseract` backend is only compiled with the `ocr` feature (it requires
/// a native Tesseract/Leptonica install). Without it, images produce no text
/// layer yet (source `"none"`), but the file itself is still ingested.
pub fn extract_image(bytes: &[u8]) -> Result<ExtractedText, IngestError> {
    #[cfg(feature = "ocr")]
    {
        use tesseract::Tesseract;
        let text = Tesseract::new(None, None)
            .and_then(|t| t.set_image_from_mem(bytes))
            .and_then(|t| t.recognize())
            .and_then(|t| t.get_text())
            .map_err(|e| IngestError::Extract(anyhow::anyhow!("ocr failed: {e}")))?;
        return Ok(ExtractedText {
            text: normalize(text),
            source: "ocr",
        });
    }

    #[cfg(not(feature = "ocr"))]
    {
        let _ = bytes;
        Ok(ExtractedText {
            text: String::new(),
            source: "none",
        })
    }
}

/// Collect the text of all leaf `text/*` parts under `parts`.
fn collect_text_parts(parts: &[&mailparse::ParsedMail]) -> String {
    let mut plain = String::new();
    let mut html = String::new();

    for part in parts {
        let ct = part.ctype.mimetype.clone();
        let sub: Vec<&mailparse::ParsedMail> = part.subparts.iter().collect();
        if sub.is_empty() {
            match ct.as_str() {
                "text/plain" => {
                    if let Ok(raw) = part.get_body_raw() {
                        plain.push_str(&String::from_utf8_lossy(&raw));
                        plain.push('\n');
                    }
                }
                "text/html" => {
                    if let Ok(raw) = part.get_body_raw() {
                        html.push_str(&String::from_utf8_lossy(&raw));
                        html.push('\n');
                    }
                }
                // Anything else is an attachment / binary part — skip it.
                _ => {}
            }
        } else {
            plain.push_str(&collect_text_parts(&sub));
        }
    }

    // Prefer the readable plain-text body; fall back to stripped HTML.
    if !plain.trim().is_empty() {
        plain
    } else {
        strip_html(&html)
    }
}

/// Read a single entry from a ZIP archive (docx/odt).
fn read_zip_entry(bytes: &[u8], candidates: &[&str]) -> Result<String, IngestError> {
    let mut archive = zip::ZipArchive::new(std::io::Cursor::new(bytes))
        .context("not a zip archive")
        .map_err(IngestError::Extract)?;

    for name in candidates {
        if let Ok(mut entry) = archive.by_name(name) {
            let mut buf = Vec::new();
            entry
                .read_to_end(&mut buf)
                .context("failed reading archive entry")
                .map_err(IngestError::Extract)?;
            return Ok(String::from_utf8_lossy(&buf).into_owned());
        }
    }
    Err(IngestError::Unsupported(format!(
        "missing {} in archive",
        candidates[0]
    )))
}

/// Validate that `s` is a UTF-8 XML string (guards against arbitrary binary
/// content slipping through the dictionary-name check).
fn xml_text(s: &str) -> Option<&str> {
    std::str::from_utf8(s.as_bytes()).ok()
}
/// Extract `<w:t>` runs from a docx XML body into paragraphs.
fn xml_wtext(xml: &str) -> String {
    let xml_text = match xml_text(xml) {
        Some(s) => s,
        None => return String::new(),
    };
    let mut reader = quick_xml::Reader::from_str(xml_text);
    // Keep whitespace intact so `<w:t xml:space="preserve">` runs that begin or
    // end with spaces survive; paragraph boundaries are handled via `<w:p>`.
    reader.config_mut().trim_text(false);

    let mut out = String::new();
    let mut cur = String::new();
    let mut buf = Vec::new();
    let mut in_t = false;

    loop {
        match reader.read_event_into(&mut buf) {
            Ok(quick_xml::events::Event::Start(e)) | Ok(quick_xml::events::Event::Empty(e)) => {
                let name = e.local_name();
                if name.as_ref() == b"t" {
                    in_t = true;
                    cur.clear();
                }
            }
            Ok(quick_xml::events::Event::End(e)) => match e.local_name().as_ref() {
                b"t" => {
                    in_t = false;
                    // Preserve leading/trailing spaces from `xml:space="preserve"`.
                    out.push_str(&cur);
                }
                b"p" => {
                    out.push('\n');
                }
                _ => {}
            },
            Ok(quick_xml::events::Event::Text(t)) => {
                if in_t {
                    cur.push_str(&decoded_bytes(t.as_ref()));
                }
            }
            Ok(quick_xml::events::Event::CData(t)) => {
                if in_t {
                    cur.push_str(&decoded_bytes(t.as_ref()));
                }
            }
            Ok(quick_xml::events::Event::Eof) | Err(_) => break,
            _ => {}
        }
        buf.clear();
    }

    out
}

/// Extract `<text:p>` paragraphs from an ODF content.xml.
fn odt_paragraphs(xml: &str) -> String {
    let xml_text = match xml_text(xml) {
        Some(s) => s,
        None => return String::new(),
    };
    let mut reader = quick_xml::Reader::from_str(xml_text);
    reader.config_mut().trim_text(true);

    let mut out = String::new();
    let mut depth = 0usize;
    let mut in_text_p = false;
    let mut buf = Vec::new();

    loop {
        match reader.read_event_into(&mut buf) {
            Ok(quick_xml::events::Event::Start(e)) => {
                let name = e.local_name();
                depth += 1;
                if !in_text_p && name.as_ref() == b"p" {
                    in_text_p = true;
                }
            }
            Ok(quick_xml::events::Event::Empty(_)) => {}
            Ok(quick_xml::events::Event::End(e)) => {
                if in_text_p && e.local_name().as_ref() == b"p" {
                    in_text_p = false;
                    out.push('\n');
                }
                depth = depth.saturating_sub(1);
            }
            Ok(quick_xml::events::Event::Text(t)) => {
                if in_text_p {
                    out.push_str(&decoded_bytes(t.as_ref()));
                }
            }
            Ok(quick_xml::events::Event::CData(t)) => {
                if in_text_p {
                    out.push_str(&decoded_bytes(t.as_ref()));
                }
            }
            Ok(quick_xml::events::Event::Eof) | Err(_) => break,
            _ => {}
        }
        buf.clear();
    }

    out
}

/// Decode raw XML text bytes to a UTF-8 `String`, unescaping entities.
fn decoded_bytes(bytes: &[u8]) -> String {
    let raw = String::from_utf8_lossy(bytes);
    quick_xml::escape::unescape(&raw)
        .map(|c| c.into_owned())
        .unwrap_or_else(|_| raw.into_owned())
}

/// Strip HTML tags and decode the most common entities, for the
/// `text/html`-only email fallback.
///
/// A small state machine that walks the bytes once: it removes tags and skips
/// the body of `<script>`/`<style>` blocks, converting block-level tags to
/// newlines so paragraphs survive.
fn strip_html(html: &str) -> String {
    let mut out = String::new();
    let mut in_tag = false;
    let mut skip: Option<String> = None; // `script`, `style`, ...
    let mut i = 0;
    let bytes = html.as_bytes();

    let mut current_tag = String::new();

    while i < bytes.len() {
        if in_tag {
            current_tag.clear();
            while i < bytes.len() && bytes[i] != b'>' {
                if bytes[i].is_ascii_alphabetic() {
                    current_tag.push(bytes[i] as char);
                }
                i += 1;
            }
            if i >= bytes.len() {
                break;
            }
            i += 1;
            in_tag = false;

            let tag = current_tag.to_ascii_lowercase();
            if tag == "script" || tag == "style" {
                skip = Some(tag.clone());
            } else if matches!(
                tag.as_str(),
                "p" | "div"
                    | "br"
                    | "li"
                    | "tr"
                    | "blockquote"
                    | "pre"
                    | "h1"
                    | "h2"
                    | "h3"
                    | "h4"
                    | "h5"
                    | "h6"
            ) && !out.ends_with('\n')
            {
                out.push('\n');
            }
            continue;
        }

        if let Some(name) = &skip {
            if let Some(rel) = html[i..].find(&format!("</{name}")) {
                i += rel + 2 + name.len();
                skip = None;
                continue;
            }
            break;
        }

        match bytes[i] {
            b'<' => {
                in_tag = true;
                i += 1;
            }
            _ => {
                out.push(bytes[i] as char);
                i += 1;
            }
        }
    }

    let joined = out
        .lines()
        .map(str::trim)
        .filter(|l| !l.is_empty())
        .collect::<Vec<_>>()
        .join("\n");
    html_unescape(&joined)
}

fn html_unescape(s: &str) -> String {
    s.replace("&amp;", "&")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&quot;", "\"")
        .replace("&#39;", "'")
        .replace("&nbsp;", " ")
}

/// Decode UTF-8 / UTF-16-BOM / Latin-1 bytes into a `String`.
fn decode_text(bytes: &[u8]) -> String {
    if bytes.starts_with(&[0xFF, 0xFE]) {
        return decode_utf16(&bytes[2..], false);
    }
    if bytes.starts_with(&[0xFE, 0xFF]) {
        return decode_utf16(&bytes[2..], true);
    }
    match std::str::from_utf8(bytes) {
        Ok(s) => s.to_owned(),
        Err(_) => bytes.iter().map(|&b| b as char).collect(),
    }
}

/// Decode UTF-16 (LE or BE) code units from `bytes`.
///
/// `array_chunks::<2>()` is not stabilized for slices on all supported
/// toolchains, so `chunks_exact(2)` + a manual loop is intentional.
#[allow(clippy::chunks_exact_to_as_chunks)]
fn decode_utf16(bytes: &[u8], big_endian: bool) -> String {
    let mut units = Vec::with_capacity(bytes.len() / 2);
    for c in bytes.chunks_exact(2) {
        units.push(if big_endian {
            u16::from_be_bytes([c[0], c[1]])
        } else {
            u16::from_le_bytes([c[0], c[1]])
        });
    }
    String::from_utf16_lossy(&units)
}

/// Normalize newlines to `\n`, trim trailing whitespace, and collapse runs of
/// blank lines (keeps indexes small; content lossless enough for search).
fn normalize(s: String) -> String {
    let mut out = String::with_capacity(s.len());
    let mut prev_blank = false;
    for line in s.lines() {
        let line = line.trim_end();
        if line.trim().is_empty() {
            if !prev_blank {
                out.push('\n');
            }
            prev_blank = true;
        } else {
            out.push_str(line);
            out.push('\n');
            prev_blank = false;
        }
    }
    while out.ends_with('\n') {
        out.pop();
    }
    out
}
