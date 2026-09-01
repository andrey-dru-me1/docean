//! Flutter bridge surface for the file ingestion pipeline.
//!
//! Follows the same shape as [`crate::api::storage`]: the repository handle is a
//! thin `Arc<Mutex>` wrapper over the SQLite + blob store, and the concrete
//! pipeline method runs synchronously (blocking) on the FRB worker thread while
//! emitting [`IngestEvent`]s over a Dart `Stream` (FRB "stream mode", like
//! `crate::api::p2p::p2p_events`).
//!
//! # NOTE (temporary, remove after codegen)
//!
//! The `SseEncode`/`SseDecode` implementations for [`IngestEvent`] below are
//! **manual stand-ins** so the crate compiles without first running
//! `flutter_rust_bridge_codegen generate` (the FRB toolchain is unavailable in
//! the development sandbox). After running `just codegen` (which has the Flutter
//! SDK), delete these impls — the generated `core/src/frb_generated.rs` will
//! provide identical ones, and keeping both would be a duplicate-definition
//! compile error.

use serde::{Deserialize, Serialize};

use crate::api::storage::DocumentRepository;
use crate::ingest::{
    FileInfo, IngestError, IngestOption, IngestPipeline, ProgressEvent, ProgressSink,
};

/// A single progress event pushed over the Dart stream while files are
/// ingested. Kept as a plain struct/string DTO (not a data-carrying enum) so
/// the generated Dart binding is a simple class.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct IngestEvent {
    /// Event kind: `"processing"`, `"extracting"`, `"completed"`, or `"failed"`.
    pub kind: String,
    /// File name (basename) the event concerns.
    pub file_name: String,
    /// 0..=100 for extracting events; 0 otherwise.
    pub percent: u32,
    /// Document id for completed events; empty otherwise.
    pub document_id: String,
    /// Error message for failed events; empty otherwise.
    pub error: String,
}

impl From<ProgressEvent> for IngestEvent {
    fn from(e: ProgressEvent) -> Self {
        match e {
            ProgressEvent::Processing { file_name } => IngestEvent {
                kind: "processing".to_owned(),
                file_name,
                percent: 0,
                document_id: String::new(),
                error: String::new(),
            },
            ProgressEvent::Extracting { file_name, percent } => IngestEvent {
                kind: "extracting".to_owned(),
                file_name,
                percent,
                document_id: String::new(),
                error: String::new(),
            },
            ProgressEvent::Completed {
                file_name,
                document_id,
            } => IngestEvent {
                kind: "completed".to_owned(),
                file_name,
                percent: 100,
                document_id,
                error: String::new(),
            },
            ProgressEvent::Failed { file_name, error } => IngestEvent {
                kind: "failed".to_owned(),
                file_name,
                percent: 0,
                document_id: String::new(),
                error,
            },
        }
    }
}

/// A progress sink that forwards events into an FRB [`StreamSink`].
struct FfiProgressSink {
    sink: crate::frb_generated::StreamSink<IngestEvent>,
}

impl crate::ingest::ProgressSink for FfiProgressSink {
    fn add(&mut self, event: ProgressEvent) -> bool {
        self.sink.add(event.into()).is_ok()
    }
}

/// Build the bridge options from the plain FRB strings.
fn to_ingest_option(
    destination_path: Option<String>,
    title_override: Option<String>,
    skip_existing: bool,
) -> IngestOption {
    IngestOption {
        destination_path,
        title_override,
        skip_existing,
    }
}

/// Ingest a batch of files from disk into the repository.
///
/// FRB "stream mode" (like `crate::api::p2p::p2p_events`): the Dart call site
/// returns a `Stream<IngestEvent>` carrying one event per file
/// (`processing` → `extracting` → `completed`/`failed`). The document id for a
/// successful file is delivered inside the `completed` event's `document_id`
/// field, so no second return channel is needed. The processing happens on the
/// FRB worker thread (blocking) while events flow through the sink.
#[flutter_rust_bridge::frb]
pub fn ingest_files(
    repo: DocumentRepository,
    paths: Vec<String>,
    destination_path: Option<String>,
    title_override: Option<String>,
    skip_existing: bool,
    sink: crate::frb_generated::StreamSink<IngestEvent>,
) -> Result<(), String> {
    let pipeline = IngestPipeline::new();
    let opts = to_ingest_option(destination_path, title_override, skip_existing);
    let mut ffi_sink = FfiProgressSink { sink };

    for path in paths {
        let info = match FileInfo::from_path(std::path::Path::new(&path)) {
            Ok(info) => info,
            Err(e) => {
                let name = std::path::Path::new(&path)
                    .file_name()
                    .map(|s| s.to_string_lossy().into_owned())
                    .unwrap_or_else(|| path.clone());
                ffi_sink.add(ProgressEvent::Failed {
                    file_name: name,
                    error: e.to_string(),
                });
                continue;
            }
        };

        let mut store = match repo.store() {
            Ok(s) => s,
            Err(e) => return Err(e),
        };

        match pipeline.ingest(
            &mut *store,
            std::slice::from_ref(&info),
            &opts,
            Some(&mut ffi_sink),
        ) {
            Ok(_) => {}
            Err(IngestError::Unsupported(ext)) => {
                let name = info
                    .path
                    .file_name()
                    .map(|s| s.to_string_lossy().into_owned())
                    .unwrap_or_default();
                ffi_sink.add(ProgressEvent::Failed {
                    file_name: name,
                    error: format!("unsupported file type {ext}"),
                });
            }
            Err(e) => {
                // The stream already received events for any files that
                // succeeded before this one failed.
                let name = info
                    .path
                    .file_name()
                    .map(|s| s.to_string_lossy().into_owned())
                    .unwrap_or_default();
                ffi_sink.add(ProgressEvent::Failed {
                    file_name: name,
                    error: e.to_string(),
                });
            }
        }
    }

    Ok(())
}

// ==========================================================================
// TEMPORARY MANUAL FRB CODEGEN (remove after `just codegen`)
//
// These mirror exactly what `flutter_rust_bridge_codegen generate` writes into
// `core/src/frb_generated.rs` for an `#[frb]` struct used in a `StreamSink`.
// They are needed here only because the codegen CLI cannot run in this
// sandbox (the Flutter SDK is not wired up). The codegen tool activates the
// `frb_expand` cfg while re-parsing the crate, so these stand-ins disappear
// during regeneration and the generated `frb_generated.rs` supplies the
// canonical impls without a duplicate-definition conflict.
// ==========================================================================
#[cfg(not(frb_expand))]
impl crate::frb_generated::SseEncode for crate::api::ingest::IngestEvent {
    fn sse_encode(self, serializer: &mut flutter_rust_bridge::for_generated::SseSerializer) {
        <String>::sse_encode(self.kind, serializer);
        <String>::sse_encode(self.file_name, serializer);
        <u32>::sse_encode(self.percent, serializer);
        <String>::sse_encode(self.document_id, serializer);
        <String>::sse_encode(self.error, serializer);
    }
}

#[cfg(not(frb_expand))]
impl crate::frb_generated::SseDecode for crate::api::ingest::IngestEvent {
    fn sse_decode(deserializer: &mut flutter_rust_bridge::for_generated::SseDeserializer) -> Self {
        let var_kind = <String>::sse_decode(deserializer);
        let var_file_name = <String>::sse_decode(deserializer);
        let var_percent = <u32>::sse_decode(deserializer);
        let var_document_id = <String>::sse_decode(deserializer);
        let var_error = <String>::sse_decode(deserializer);
        crate::api::ingest::IngestEvent {
            kind: var_kind,
            file_name: var_file_name,
            percent: var_percent,
            document_id: var_document_id,
            error: var_error,
        }
    }
}
