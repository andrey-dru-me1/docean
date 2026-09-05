//! File ingestion pipeline.
//!
//! **Boundary:** accept files dropped into the app, compute their content hash,
//! copy the bytes into the content-addressed [`BlobStore`], and extract a
//! plain-text layer. Produces a [`Document`] (metadata record) plus a [`Content`]
//! row per file. The pipeline itself stores metadata with **empty tags**; the
//! deterministic auto-organization pass (tags + title + placement) is applied
//! *after* a file is persisted, by [`crate::api::ingest::ingest_files`] via
//! `crate::auto_org`.
//!
//! # Pipeline stages (per file)
//!
//! 1. **Probe** — stat the file; read bytes; classify the kind by extension.
//! 2. **Copy** — `store.put()` writes the bytes into the content-addressed blob
//!    store (deduplicating identical bytes) and returns the SHA-256.
//! 3. **Extract** — run the text extractor for the detected format.
//! 4. **Index** — `store.put(document)` + `store.put_content(content)`.
//!
//! Each of these stages is reported to an optional [`ProgressSink`] so Dart can
//! render progress bars; see [`ingest_files`] in `crate::api` for the bridge.
//!
//! # Deduplication
//!
//! The document id is the SHA-256 of the file bytes (the blob hash). Ingesting
//! the same bytes twice upserts to the same document (the second write wins the
//! title/metadata), while the blob is written to disk only once. Distinct files
//! always produce distinct documents even when their bytes collide (a content
//! hash collision is treated as a duplicate because the content address is the
//! identity).

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use crate::domain::{Content, Document, NodeKind};
use crate::storage::{hash_bytes, DocumentStore, StorageError};

pub(crate) mod text;

#[cfg(test)]
mod tests;

use text::{extract, ExtractedText, Format};

/// Errors returned by the ingestion pipeline.
#[derive(Debug, thiserror::Error)]
pub enum IngestError {
    #[error("io error: {0}")]
    Io(#[from] std::io::Error),
    #[error("storage error: {0}")]
    Storage(#[from] StorageError),
    #[error("text extraction failed: {0}")]
    Extract(#[source] anyhow::Error),
    #[error("unsupported file type: {0}")]
    Unsupported(String),
}

/// Options controlling one batch of ingestion.
#[derive(Debug, Clone, Default)]
pub struct IngestOption {
    /// Optional folder prefix for the resulting documents (matches an existing
    /// `HierarchyPath`). When `None`, no path is assigned.
    pub destination_path: Option<String>,
    /// Override the display title for the first file only (for batches).
    /// `None` falls back to the file's stem.
    pub title_override: Option<String>,
    /// If `true`, files whose bytes already exist in the blob store are skipped
    /// (no `Completed` event). Defaults to `false` (always ingest).
    pub skip_existing: bool,
}

/// Metadata describing a file on disk, mirroring the OS stat result.
#[derive(Debug, Clone)]
pub struct FileInfo {
    /// Absolute or relative path as given by the caller.
    pub path: PathBuf,
    /// File size in bytes.
    pub size: u64,
    /// Last-modified time, ms since Unix epoch (0 = unknown).
    pub modified_ms: i64,
    /// Creation time where available, ms since Unix epoch (0 = unknown).
    pub created_ms: i64,
}

impl FileInfo {
    /// Stat `path` into a [`FileInfo`]. Timestamps are best-effort.
    pub fn from_path(path: &Path) -> std::io::Result<FileInfo> {
        let md = std::fs::metadata(path)?;
        Ok(FileInfo {
            path: path.to_path_buf(),
            size: md.len(),
            modified_ms: system_time_to_ms(md.modified()),
            created_ms: system_time_to_ms(md.created()),
        })
    }
}

fn system_time_to_ms(t: std::io::Result<SystemTime>) -> i64 {
    match t {
        Ok(t) => t
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_millis() as i64)
            .unwrap_or(0),
        Err(_) => 0,
    }
}

/// One event emitted while ingesting a file.
#[derive(Debug, Clone, PartialEq)]
pub enum ProgressEvent {
    /// About to copy the file bytes into the blob store.
    Processing { file_name: String },
    /// Text extraction in progress (PDF pages, OCR chunks, etc.).
    Extracting {
        file_name: String,
        /// 0..=100 across the extraction phase.
        percent: u32,
    },
    /// The file was fully ingested (metadata + blob + content stored).
    Completed {
        file_name: String,
        document_id: String,
    },
    /// The file was skipped because it already exists (hash match).
    Skipped { file_name: String },
    /// The file could not be ingested.
    Failed { file_name: String, error: String },
}

/// A sink that receives [`ProgressEvent`]s. The bridge wraps this with an FRB
/// `StreamSink`; tests use a collecting vec.
pub trait ProgressSink: Send {
    /// Push an event. Returns `false` if the sink is closed (callee should stop).
    fn add(&mut self, event: ProgressEvent) -> bool;
}

/// A [`ProgressSink`] that records events in a [`Vec`] (tests, capture).
#[derive(Debug, Default, Clone)]
pub struct VecProgressSink {
    pub events: Vec<ProgressEvent>,
}

impl ProgressSink for VecProgressSink {
    fn add(&mut self, event: ProgressEvent) -> bool {
        self.events.push(event);
        true
    }
}

impl VecProgressSink {
    /// New, empty capture sink.
    pub fn new() -> Self {
        Self::default()
    }
}

/// The ingestion pipeline.
///
/// It is cheap to construct (`Clone`) and holds no mutable state of its own;
/// all durable state lives in the [`DocumentStore`] it is told to ingest into.
#[derive(Debug, Clone, Copy)]
pub struct IngestPipeline {
    _private: (),
}

impl Default for IngestPipeline {
    fn default() -> Self {
        Self::new()
    }
}

impl IngestPipeline {
    /// Construct a new pipeline.
    pub const fn new() -> Self {
        Self { _private: () }
    }

    /// Ingest a batch of files.
    ///
    /// Each file is processed sequentially:
    /// 1. read + hash,
    /// 2. `store.put()` (copy into the content-addressed blob store),
    /// 3. text extraction,
    /// 4. `store.put()` document metadata + `store.put_content()` extracted text.
    ///
    /// The optional `progress` sink receives one [`ProgressEvent`] per file.
    /// Returns the id of every document written (one per file, in order).
    pub fn ingest(
        &self,
        store: &mut dyn DocumentStore,
        files: &[FileInfo],
        opts: &IngestOption,
        mut progress: Option<&mut dyn ProgressSink>,
    ) -> Result<Vec<String>, IngestError> {
        let mut ids = Vec::with_capacity(files.len());
        for (i, info) in files.iter().enumerate() {
            let name = info
                .path
                .file_name()
                .map(|s| s.to_string_lossy().into_owned())
                .unwrap_or_else(|| info.path.display().to_string());
            let file_name = name.clone();

            if let Some(p) = progress.as_deref_mut() {
                if !p.add(ProgressEvent::Processing {
                    file_name: file_name.clone(),
                }) {
                    break;
                }
            }

            let bytes = std::fs::read(&info.path)?;
            let hash = hash_bytes(&bytes);

            // Deduplication: if the bytes already exist as a document, and the
            // caller asked to skip, we're done (but still emit a summary id).
            if opts.skip_existing {
                match store.get(&hash) {
                    Ok(_) => {
                        if let Some(p) = progress.as_deref_mut() {
                            p.add(ProgressEvent::Skipped {
                                file_name: file_name.clone(),
                            });
                        }
                        ids.push(hash.clone());
                        continue;
                    }
                    Err(StorageError::NotFound(_)) => {}
                    Err(e) => return Err(e.into()),
                }
            }

            let text = self.extract(&name, &bytes, &mut progress);

            let (text, source) = match text {
                Ok(ExtractedText { text, source }) => (text, source),
                Err(IngestError::Unsupported(ext)) => {
                    let msg = format!("unsupported file type {ext}");
                    if let Some(p) = progress.as_deref_mut() {
                        p.add(ProgressEvent::Failed {
                            file_name,
                            error: msg.clone(),
                        });
                    }
                    return Err(IngestError::Unsupported(ext));
                }
                Err(e) => return Err(e),
            };

            let doc = Self::build_document(info, &name, &hash, source, &bytes, opts, i);

            store.put(doc, &bytes)?;
            store.put_content(&Content {
                document_id: hash.clone(),
                text,
                source: source.to_owned(),
            })?;

            ids.push(hash.clone());

            if let Some(p) = progress.as_deref_mut() {
                p.add(ProgressEvent::Completed {
                    file_name,
                    document_id: hash,
                });
            }
        }
        Ok(ids)
    }

    /// Ingest a single file (convenience wrapper).
    pub fn ingest_one(
        &self,
        store: &mut dyn DocumentStore,
        path: &Path,
        opts: &IngestOption,
        progress: Option<&mut dyn ProgressSink>,
    ) -> Result<String, IngestError> {
        let info = FileInfo::from_path(path)?;
        let ids = self.ingest(store, &[info], opts, progress)?;
        ids.into_iter()
            .next()
            .ok_or_else(|| IngestError::Io(std::io::Error::other("ingest returned no document id")))
    }

    /// Run text extraction, forwarding a progress event for the extraction
    /// phase (PDF/OCR could chunk; here it's a single step at 100% when done).
    fn extract(
        &self,
        name: &str,
        bytes: &[u8],
        progress: &mut Option<&mut dyn ProgressSink>,
    ) -> Result<ExtractedText, IngestError> {
        let file_name = name.to_owned();
        if let Some(p) = progress.as_mut() {
            p.add(ProgressEvent::Extracting {
                file_name: file_name.clone(),
                percent: 0,
            });
        }

        let ext = extension_of(name);
        let result = extract(&ext, bytes);

        if let Some(p) = progress.as_mut() {
            p.add(ProgressEvent::Extracting {
                file_name,
                percent: 100,
            });
        }
        result
    }
    /// Build the [`Document`] metadata record for one ingested file.
    fn build_document(
        info: &FileInfo,
        name: &str,
        hash: &str,
        source: &str,
        bytes: &[u8],
        opts: &IngestOption,
        index: usize,
    ) -> Document {
        let title = if index == 0 {
            opts.title_override.clone().unwrap_or_else(|| stem_of(name))
        } else {
            stem_of(name)
        };

        let mime = mime_for(extension_of(name), source);

        let mut extra = HashMap::new();
        extra.insert("original_name".to_owned(), name.to_owned());
        extra.insert("extractor".to_owned(), source.to_owned());
        if let Some(parent) = &opts.destination_path {
            extra.insert("destination_path".to_owned(), parent.clone());
        }

        let now = now_millis();
        Document {
            // The document identity is the content address (SHA-256 hex).
            id: hash.to_owned(),
            parent_id: None,
            kind: NodeKind::Document,
            title,
            mime_type: mime,
            size_bytes: bytes.len() as u64,
            checksum_sha256: hash.to_owned(),
            tags: Vec::new(),
            created_at_ms: info.created_ms.max(now),
            updated_at_ms: info.modified_ms.max(now),
            extra,
        }
    }
}

/// The extension of `name`, lowercase, without the dot.
pub(crate) fn extension_of(name: &str) -> String {
    name.rsplit('.')
        .next()
        .map(|s| s.to_ascii_lowercase())
        .unwrap_or_default()
}

/// The file stem (basename without final extension).
pub(crate) fn stem_of(name: &str) -> String {
    match name.rfind('.') {
        Some(i) if i > 0 => name[..i].to_owned(),
        _ => name.to_owned(),
    }
}

/// Map an extracted format to a MIME type.
pub(crate) fn mime_for(ext: String, source: &str) -> String {
    match text::classify(&ext) {
        Format::Pdf => "application/pdf".to_owned(),
        Format::PlainText => "text/plain".to_owned(),
        Format::Markdown => "text/markdown".to_owned(),
        Format::Docx => {
            "application/vnd.openxmlformats-officedocument.wordprocessingml.document".to_owned()
        }
        Format::Odt => "application/vnd.oasis.opendocument.text".to_owned(),
        Format::Email => "message/rfc822".to_owned(),
        Format::Image => match ext.as_str() {
            "png" => "image/png".to_owned(),
            "jpg" | "jpeg" => "image/jpeg".to_owned(),
            "gif" => "image/gif".to_owned(),
            "bmp" => "image/bmp".to_owned(),
            "tiff" | "tif" => "image/tiff".to_owned(),
            "webp" => "image/webp".to_owned(),
            "heic" => "image/heic".to_owned(),
            _ => "application/octet-stream".to_owned(),
        },
        Format::Unsupported | Format::Unknown => {
            if source == "plain" {
                "text/plain".to_owned()
            } else {
                "application/octet-stream".to_owned()
            }
        }
    }
}

pub(crate) fn now_millis() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}
