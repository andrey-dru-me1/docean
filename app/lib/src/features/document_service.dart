/// A thin, typed facade over the generated storage + search bindings that
/// exposes the persisted document library to the UI.
///
/// Mirrors the service-injection/testability pattern of
/// [`SearchService`](search_service.dart) and
/// [`IngestService`](ingest_service.dart): the interface is what the UI depends
/// on, the bridge-backed implementation is the production default, and fakes
/// (e.g. [FakeDocumentService]) are used in widget tests without loading the
/// native library.
library;

import 'dart:convert';

import '../rust/api/auto_org.dart'
    show
        autoOrgApplySuggestion,
        autoOrgConfirmCurrent,
        autoOrgDefaultConfig,
        autoOrgDismissSuggestion,
        autoOrgListSuggestions,
        autoOrgOrganize,
        autoOrgReorganizeAll,
        autoOrgReorganizeOne,
        autoOrgReorganizeSelected,
        autoOrgResetLearning,
        autoOrgResolveManualEdit,
        autoOrgSuggestTags,
        autoOrgSuggestTitle;
import '../rust/api/search.dart' as search_bridge;
import '../rust/api/storage.dart' show DocumentRepository;
import '../rust/api/library.dart' as library_bridge;
import '../rust/auto_org/config.dart' show OrgConfig;
import 'learning_prefs.dart' show suggestionLearningMode;
import '../rust/auto_org/feedback.dart' show LearningMode;
import '../rust/domain.dart'
    show
        Document,
        DocumentSuggestion,
        NodeKind,
        SavedView,
        SuggestionKind,
        SuggestionSource,
        SuggestionStatus;
import '../rust/api/auto_org.dart' show SuggestOutcome;
import '../rust/storage.dart' show DocumentQuery;
import '../ui/document_view.dart' show DocumentSummary;
import 'tag_hierarchy.dart' show expandTagAncestors;
import 'repository.dart' show openSharedRepository;

/// The heavy-lifting bulk re-organization pipeline.
///
/// Kept out of [DocumentService] so fakes/tests of the Documents bulk toolkit
/// don't need to implement it; the production instance runs the deterministic
/// auto-organization pass via the Rust bridge.
abstract interface class BulkOrganizer {
  /// Re-run the deterministic auto-organization pass across **all** documents,
  /// preserving every user's manual edits (the `title_manual` / `tags_manual`
  /// flags are honored inside the core, so hand-edited metadata is never
  /// clobbered). Returns aggregate counts; the pass needs no AI provider.
  Future<ReorganizeResult> reorganizeAll();

  /// Re-run the deterministic auto-organization pass on **only** the given
  /// [ids], preserving every user's manual edits.  The async signature ensures
  /// the heavy Rust work runs off the UI isolate.
  Future<ReorganizeResult> reorganizeSelected(Set<String> ids);
}

/// The production [BulkOrganizer] backed by the Rust bridge.
///
/// Uses `autoOrgReorganizeAll` for the corpus-wide pass and the async
/// `autoOrgReorganizeSelected` for the selection-scoped action (runs on
/// Rust's async worker pool so the Flutter UI isolate is never blocked).
class DoceanBulkOrganizer implements BulkOrganizer {
  const DoceanBulkOrganizer();

  @override
  Future<ReorganizeResult> reorganizeAll() async {
    final repo = await openSharedRepository();
    final stats = autoOrgReorganizeAll(
      repo: repo,
      config: autoOrgDefaultConfig(),
    );
    return ReorganizeResult(
      total: stats.total.toInt(),
      updated: stats.updated.toInt(),
      skipped: stats.skipped.toInt(),
    );
  }

  @override
  Future<ReorganizeResult> reorganizeSelected(Set<String> ids) async {
    if (ids.isEmpty) {
      return const ReorganizeResult(total: 0, updated: 0, skipped: 0);
    }
    final repo = await openSharedRepository();
    // autoOrgReorganizeSelected is a `#[frb]` async bridge: FRB runs it on
    // Rust's worker pool, so the Dart UI isolate stays responsive.
    final stats = await autoOrgReorganizeSelected(
      repo: repo,
      ids: ids.toList(),
      config: autoOrgDefaultConfig(),
    );
    return ReorganizeResult(
      total: stats.total.toInt(),
      updated: stats.updated.toInt(),
      skipped: stats.skipped.toInt(),
    );
  }
}

/// A [BulkOrganizer] with no work to do — the default injected into
/// [DocumentsScreen] so the selection toolbar works (and tests pass) without
/// the native library loaded.
class NoopBulkOrganizer implements BulkOrganizer {
  const NoopBulkOrganizer();

  @override
  Future<ReorganizeResult> reorganizeAll() async =>
      const ReorganizeResult(total: 0, updated: 0, skipped: 0);

  @override
  Future<ReorganizeResult> reorganizeSelected(Set<String> ids) async =>
      const ReorganizeResult(total: 0, updated: 0, skipped: 0);
}

/// The document-library service contract. Implement with the Rust bridge,
/// fakes in tests.
abstract interface class DocumentService {
  /// List every persisted document (metadata from `repo.query`), newest first,
  /// with tags resolved from the repository.
  Future<List<DocumentSummary>> listDocuments();

  /// Fresh metadata for a single document (used by the detail view to reflect
  /// tag edits and to resolve the original file name / MIME type).
  Future<DocumentSummary> getDocument(String id);

  /// The extracted plain-text content for a document, or `null` when the
  /// document has none yet (e.g. images without OCR).
  Future<String?> getContent(String id);

  /// The document's raw bytes, read from the content-addressed blob store.
  Future<List<int>> readBytes(String id);

  /// Replace the document's tag set, persisting the assignment in the
  /// repository and mirroring it into the in-memory search metadata so results
  /// can be filtered by the new tags immediately.
  Future<void> setTags(String id, List<String> tags);

  /// Persist a new title for a document through the repository (`repo.put`,
  /// reusing the stored raw bytes) and mirror the new title into the search
  /// index so the rename is immediately searchable.
  Future<void> updateTitle(String id, String title);

  /// Run the existing deterministic auto-organization bridge
  /// (`auto_org_organize`) and return the suggested title + tags. Suggestion
  /// only — callers decide whether to apply, typically honoring the
  /// `title_manual`/`tags_manual` flags on the document's `extra` metadata.
  Future<SuggestionPlan> suggestMetadata(String id);

  /// Suggest a title for a document and — unless the user manually renamed it
  /// (`extra['title_manual']`) — persist it through [updateTitle].
  ///
  /// Runs the deterministic organizer in the background; the returned plan's
  /// `tags` list is empty because this action owns only the title.
  Future<SuggestionPlan> suggestTitle(String id);

  /// Suggest tags for a document and — unless the user manually tagged it
  /// (`extra['tags_manual']`) — persist them through [setTags].
  ///
  /// Runs the deterministic organizer in the background; the returned plan's
  /// `title` is `null` because this action owns only the tags.
  Future<SuggestionPlan> suggestTags(String id);

  /// Permanently delete a document (and, when unreferenced, its blob) from the
  /// repository, and drop it from the in-memory search index.
  Future<void> delete(String id);

  /// Re-run the deterministic auto-organization pass on a single document,
  /// honoring the manual-edit flags exactly like the bulk pass. Returns the
  /// resulting applied plan. Bridges the per-file "Suggest title & tags" button
  /// so suggestions are applied by the core without clobbering manual edits.
  Future<SuggestionPlan> reorganizeOne(String id);

  /// Every suggestion row persisted for [id] (applied rank 0 + pending
  /// alternatives), newest first per kind.
  Future<List<SuggestionEntry>> listSuggestions(String id);

  /// Apply one pending alternative suggestion by id: the core applies its
  /// payload through the normal update paths, records accept/reject feedback
  /// from the choice, and dismisses every other pending suggestion of the same
  /// kind (the "alternatives disappear after choice" contract).
  Future<void> applySuggestion(String id, String suggestionId);

  /// Keep the currently applied value for a suggestion kind: records accepted
  /// feedback for the applied terms, rejected for pending alternatives'
  /// distinctive terms, and dismisses all pending of that kind.
  Future<void> confirmCurrent(String id, SuggestionKind kind);

  /// Dismiss one pending suggestion (records reject feedback for its terms).
  Future<void> dismissSuggestion(String id, String suggestionId);

  /// Complete the suggestion review ("poll") for a kind after a user manual
  /// edit: dismisses every suggestion row of [kind] (pending alternatives and
  /// the stale applied rank-0) and — when the user's learning mode is on —
  /// records rejected feedback for generated terms the user did not keep.
  /// Returns the number of rows dismissed.
  Future<int> completeSuggestionPoll(String id, SuggestionKind kind);

  /// Wipe all learned feedback (settings "reset learning").
  Future<void> resetSuggestionFeedback();

  /// Batch tag edit across many documents: for each id, compute a new tag set
  /// by adding every tag in [add] (honoring existing tags on the document —
  /// adding appends, never duplicates) and removing every tag in [remove]
  /// (when present), then persist the result through [setTags].
  ///
  /// Empty/blank names are skipped; ids that no longer exist are ignored so a
  /// mid-run deletion can't abort the whole batch.
  Future<void> bulkTags(
    Iterable<String> ids, {
    List<String> add = const [],
    List<String> remove = const [],
  });

  /// Permanently delete many documents in one batch (see [delete]). The batch
  /// is sequential so the singleton repository handle is never contended.
  Future<void> bulkDelete(Iterable<String> ids);

  /// All tag names known to the repository (`repo.listTags`).
  Future<List<String>> listTags();

  /// Saved (pinned) filter views: named tag sets applied from the filter bar.
  Future<List<SavedView>> listSavedViews();

  /// Save or replace a named view of the given tag filters.
  Future<void> saveView(String name, List<String> tags);

  /// Delete a saved view by name.
  Future<void> deleteSavedView(String name);

  /// Rebuild the in-memory search index from the persisted repository.
  ///
  /// Called once at app startup so documents stored in previous sessions are
  /// searchable even though the ephemeral in-memory engine starts empty.
  Future<void> reindex();

  /// The on-disk path of a document's mirrored library file, when it exists.
  ///
  /// When non-null the caller can reveal/open the file directly (no temp copy
  /// needed). Returns `null` when no library is configured, the document has
  /// no stamped file name, or the file no longer exists on disk.
  Future<String?> libraryFilePath(String id);
}

/// A suggestion from the deterministic auto-organization pipeline.
///
/// Suggestion-only: nothing is persisted here by itself; the split action
/// methods ([DocumentService.suggestTitle] / [DocumentService.suggestTags])
/// persist the part they own (honoring the `title_manual`/`tags_manual` flags
/// on the document's `extra` metadata), and return the plan so the caller can
/// notify the user about what (if anything) was applied.
class SuggestionPlan {
  const SuggestionPlan({required this.title, required this.tags, this.outcome});

  /// The suggested title, or `null` when the pipeline produced none.
  final String? title;

  /// The suggested tags (ordered by confidence).
  final List<String> tags;

  /// The outcome of a suggest run (applied / already current / no suggestion),
  /// and how many pending alternatives were stored.
  final SuggestOutcome? outcome;

  /// Whether anything meaningful was suggested at all (a non-blank title or at
  /// least one tag).
  bool get isEmpty => (title == null || title!.trim().isEmpty) && tags.isEmpty;

  /// A trimmed copy of [title], or `null` when it is blank.
  String? get cleanTitle {
    final t = title?.trim();
    if (t == null || t.isEmpty) return null;
    return t;
  }
}

/// A persisted suggestion row surfaced to the document info card.
///
/// Mirrors the bridge `DocumentSuggestion` but decoupled from the generated
/// type so the UI and fakes don't depend on FRB types directly.
class SuggestionEntry {
  const SuggestionEntry({
    required this.id,
    required this.documentId,
    required this.kind,
    required this.title,
    required this.tags,
    required this.rank,
    required this.source,
    required this.status,
  });

  final String id;
  final String documentId;

  /// What this suggestion proposes: a title, or a tag set.
  final SuggestionKind kind;

  /// The suggested title (kind = Title), or `null` for tag sets.
  final String? title;

  /// The suggested tags (kind = Tags), or `const []` for titles.
  final List<String> tags;

  /// 0 = currently applied; higher = lower-priority alternative.
  final int rank;

  /// Where the suggestion came from (ingest / bulk / manual request / user).
  final SuggestionSource source;

  /// pending / applied / dismissed.
  final SuggestionStatus status;

  bool get isPending => status == SuggestionStatus.pending;
}

/// The aggregate outcome of a bulk re-organization pass (`org_bulk_stats`).
class ReorganizeResult {
  const ReorganizeResult({
    required this.total,
    required this.updated,
    required this.skipped,
  });

  /// Documents examined by the pass.
  final int total;

  /// Documents whose tags/title/placement changed as a result.
  final int updated;

  /// Documents left untouched (already matching, or manual-edit flags set).
  final int skipped;

  /// Whether anything was actually changed by the pass.
  bool get changedAnything => updated > 0;
}

/// The default implementation backed by the Rust bridge.
///
/// Shares the process-wide cached [`DocumentRepository`] with the ingestion
/// service, so files stored through [`BridgeIngestService`] are immediately
/// visible here and vice versa.
class BridgeDocumentService implements DocumentService {
  const BridgeDocumentService({this._repositoryRoot});

  final Future<String> Function()? _repositoryRoot;

  Future<DocumentRepository> _repo() =>
      openSharedRepository(root: _repositoryRoot);

  @override
  Future<List<DocumentSummary>> listDocuments() async {
    final repo = await _repo();
    final docs = await repo.query(
      query: DocumentQuery(
        kind: NodeKind.document,
        tags: const [],
        limit: 1000,
      ),
    );
    final summaries = <DocumentSummary>[];
    for (final doc in docs) {
      summaries.add(_summaryOf(doc));
    }
    return summaries;
  }

  /// Fresh metadata for a single document.
  @override
  Future<DocumentSummary> getDocument(String id) async {
    final repo = await _repo();
    final doc = await repo.get_(id: id);
    return _summaryOf(doc);
  }

  /// The extracted text for a document, if any has been persisted.
  @override
  Future<String?> getContent(String id) async {
    final repo = await _repo();
    final content = await repo.getContent(documentId: id);
    return content?.text;
  }

  /// The raw bytes of a document from the content-addressed blob store.
  @override
  Future<List<int>> readBytes(String id) async {
    final repo = await _repo();
    return await repo.readBytes(id: id);
  }

  /// Persist a document's tag set and mirror it into the search metadata.
  @override
  Future<void> setTags(String id, List<String> tags) async {
    final repo = await _repo();
    await repo.setTags(documentId: id, tags: tags);
    try {
      search_bridge.searchSetMetadata(documentId: id, tags: tags);
    } catch (_) {
      // If the search metadata is unavailable the tags are still persisted in
      // the repository; search filtering simply falls back to repository-source.
    }
  }

  /// Persist a renamed title through the repository's `updateTitle` binding
  /// (stamps `title_manual` and records accept feedback exactly like the tags
  /// path) and mirror the new title into the search metadata.
  @override
  Future<void> updateTitle(String id, String title) async {
    final repo = await _repo();
    await repo.updateTitle(documentId: id, title: title);
    // Best-effort search-metadata mirror (mirrors the setTags pattern).
    try {
      final doc = await repo.get_(id: id);
      search_bridge.searchSetMetadata(documentId: id, tags: doc.tags);
    } catch (_) {
      // Persisted regardless of search-index availability.
    }
  }

  /// The auto-organization config with the user-selected learning mode applied.
  OrgConfig _orgConfig() {
    final config = autoOrgDefaultConfig();
    return OrgConfig(
      enabled: config.enabled,
      generativeEnabled: config.generativeEnabled,
      dedupThreshold: config.dedupThreshold,
      shingleK: config.shingleK,
      clusterK: config.clusterK,
      rules: config.rules,
      learningMode: suggestionLearningMode(),
    );
  }

  /// Run the existing deterministic auto-organization bridge over the whole
  /// corpus and return its suggestion (nothing is persisted here).
  @override
  Future<SuggestionPlan> suggestMetadata(String id) async {
    final repo = await _repo();
    final plan = await autoOrgOrganize(
      repo: repo,
      documentId: id,
      config: _orgConfig(),
    );
    return SuggestionPlan(title: plan.suggestedTitle, tags: List.of(plan.tags));
  }

  /// Suggest a title and apply it (unless the user manually renamed the
  /// document). See [DocumentService.suggestTitle].
  ///
  /// Runs on the main isolate but never blocks the UI: `auto_org_organize` is
  /// an `async` bridge function, so FRB executes the deterministic pass on
  /// Rust's async worker pool and the Dart event loop stays free.
  @override
  Future<SuggestionPlan> suggestTitle(String id) async {
    final repo = await _repo();
    final outcome = await autoOrgSuggestTitle(
      repo: repo,
      documentId: id,
      config: _orgConfig(),
    );
    // The core applied a top suggestion + stored alternatives (incl. old
    // title). Re-read to reflect the change so the caller can show it.
    final fresh = await repo.get_(id: id);
    return SuggestionPlan(
      title: fresh.title,
      tags: const [],
      outcome: SuggestOutcome(
        status: outcome.status,
        storedPending: outcome.storedPending,
      ),
    );
  }

  /// Suggest tags and apply them (unless the user manually tagged the
  /// document). See [DocumentService.suggestTags].
  ///
  /// Runs on the main isolate; the deterministic pass executes on Rust's async
  /// worker pool, so the UI is never blocked.
  @override
  Future<SuggestionPlan> suggestTags(String id) async {
    final repo = await _repo();
    final outcome = await autoOrgSuggestTags(
      repo: repo,
      documentId: id,
      config: _orgConfig(),
    );
    final fresh = await repo.get_(id: id);
    return SuggestionPlan(
      title: null,
      tags: fresh.tags,
      outcome: SuggestOutcome(
        status: outcome.status,
        storedPending: outcome.storedPending,
      ),
    );
  }

  /// Permanently delete a document (blob + metadata) and drop it from the
  /// in-memory search index so stale results can't resurrect it.
  @override
  Future<void> delete(String id) async {
    final repo = await _repo();
    await repo.delete(id: id);
    search_bridge.searchRemoveDocument(documentId: id);
  }

  /// Batch tag edit. Per document: read the current tags, append the [add]
  /// names (dedupe, honoring existing tags) and strip the [remove] names, then
  /// persist the merged set through the repository's `set_tags` (which also
  /// mirrors the search metadata). Sequenced so the shared repository handle
  /// is never contended; a document deleted mid-batch is simply skipped.
  @override
  Future<void> bulkTags(
    Iterable<String> ids, {
    List<String> add = const [],
    List<String> remove = const [],
  }) async {
    final adds = add.map((t) => t.trim()).where((t) => t.isNotEmpty).toSet();
    final removes = remove
        .map((t) => t.trim())
        .where((t) => t.isNotEmpty)
        .toSet();
    if (adds.isEmpty && removes.isEmpty) return;
    final repo = await _repo();
    for (final id in ids) {
      try {
        final doc = await repo.get_(id: id);
        final ordered = List<String>.of(doc.tags)
          ..addAll(adds.where((t) => !doc.tags.contains(t)))
          ..removeWhere(removes.contains);
        await repo.setTags(documentId: id, tags: ordered);
        // Best-effort: complete the suggestion poll for tags so the review
        // card disappears after a bulk manual edit (a failure must not abort
        // the batch).
        try {
          final learningMode = suggestionLearningMode();
          await autoOrgResolveManualEdit(
            repo: repo,
            documentId: id,
            kind: SuggestionKind.tags,
            recordFeedback: learningMode != LearningMode.off,
          );
        } catch (_) {
          // Poll failure must not block the bulk tag edit.
        }
      } catch (_) {
        // A document deleted mid-batch simply is skipped.
      }
    }
  }

  /// Permanently delete many documents sequentially (see [delete]).
  @override
  Future<void> bulkDelete(Iterable<String> ids) async {
    final repo = await _repo();
    for (final id in ids) {
      await repo.delete(id: id);
      search_bridge.searchRemoveDocument(documentId: id);
    }
  }

  /// Re-run the deterministic auto-organization pass on a single document,
  /// honoring the manual-edit flags. Returns the resulting applied plan.
  @override
  Future<SuggestionPlan> reorganizeOne(String id) async {
    final repo = await _repo();
    final plan = autoOrgReorganizeOne(
      repo: repo,
      documentId: id,
      config: autoOrgDefaultConfig(),
    );
    // The core applies only the parts the user has not manually set; the
    // returned plan is the (possibly partially applied) suggestion.
    return SuggestionPlan(title: plan.suggestedTitle, tags: List.of(plan.tags));
  }

  /// Every persisted suggestion row for a document, as UI-friendly entries.
  @override
  Future<List<SuggestionEntry>> listSuggestions(String id) async {
    final repo = await _repo();
    final rows = await autoOrgListSuggestions(repo: repo, documentId: id);
    return [for (final r in rows) _entryOf(r)];
  }

  @override
  Future<void> applySuggestion(String id, String suggestionId) async {
    final repo = await _repo();
    await autoOrgApplySuggestion(
      repo: repo,
      documentId: id,
      suggestionId: suggestionId,
    );
  }

  @override
  Future<void> confirmCurrent(String id, SuggestionKind kind) async {
    final repo = await _repo();
    await autoOrgConfirmCurrent(repo: repo, documentId: id, kind: kind);
  }

  @override
  Future<void> dismissSuggestion(String id, String suggestionId) async {
    final repo = await _repo();
    await autoOrgDismissSuggestion(
      repo: repo,
      documentId: id,
      suggestionId: suggestionId,
    );
  }

  @override
  Future<int> completeSuggestionPoll(String id, SuggestionKind kind) async {
    final repo = await _repo();
    final learningMode = suggestionLearningMode();
    return await autoOrgResolveManualEdit(
      repo: repo,
      documentId: id,
      kind: kind,
      recordFeedback: learningMode != LearningMode.off,
    );
  }

  @override
  Future<void> resetSuggestionFeedback() async {
    final repo = await _repo();
    await autoOrgResetLearning(repo: repo);
  }

  SuggestionEntry _entryOf(DocumentSuggestion s) {
    final tags = s.kind == SuggestionKind.tags
        ? (jsonDecode(s.payload) as List).cast<String>()
        : const <String>[];
    return SuggestionEntry(
      id: s.id,
      documentId: s.documentId,
      kind: s.kind,
      title: s.kind == SuggestionKind.title ? s.payload : null,
      tags: tags,
      rank: s.rank,
      source: s.source,
      status: s.status,
    );
  }

  DocumentSummary _summaryOf(Document doc) {
    return DocumentSummary(
      id: doc.id,
      title: doc.title,
      tags: doc.tags,
      mimeType: doc.mimeType,
      originalName: doc.extra['original_name'],
      extra: Map.of(doc.extra),
      sizeBytes: doc.sizeBytes.toInt(),
      createdAtMs: doc.createdAtMs.toInt(),
      updatedAtMs: doc.updatedAtMs.toInt(),
    );
  }

  @override
  Future<List<String>> listTags() async {
    final repo = await _repo();
    final tags = await repo.listTags();
    return [for (final t in tags) t.name];
  }

  @override
  Future<List<SavedView>> listSavedViews() async {
    final repo = await _repo();
    return repo.listSavedViews();
  }

  @override
  Future<void> saveView(String name, List<String> tags) async {
    final repo = await _repo();
    await repo.saveView(name: name, tags: tags);
  }

  @override
  Future<void> deleteSavedView(String name) async {
    final repo = await _repo();
    await repo.deleteSavedView(name: name);
  }

  @override
  Future<void> reindex() async {
    final repo = await _repo();
    search_bridge.searchReindexFromRepository(repo: repo);
  }

  @override
  Future<String?> libraryFilePath(String id) async {
    final repo = await _repo();
    return library_bridge.libraryFilePath(repo: repo, id: id);
  }
}

/// Returns [doc] with hierarchical-tag ancestors materialized (core parity:
/// a doc tagged `study/mit/ml` also carries `study`, `study/mit`). Returns
/// [doc] itself when there is nothing to expand.
DocumentSummary _withMaterializedAncestors(DocumentSummary doc) {
  final expanded = expandTagAncestors(doc.tags);
  if (expanded.length == doc.tags.length && expanded.containsAll(doc.tags)) {
    return doc;
  }
  return DocumentSummary(
    id: doc.id,
    title: doc.title,
    snippet: doc.snippet,
    tags: expanded.toList(),
    mimeType: doc.mimeType,
    originalName: doc.originalName,
    extra: doc.extra,
  );
}

class FakeDocumentService implements DocumentService {
  FakeDocumentService({
    List<DocumentSummary> documents = const [],
    List<String> tags = const [],
    Map<String, String> contentByDocumentId = const {},
    Map<String, List<int>> bytesByDocumentId = const {},
    this.suggestion,
    Map<String, List<SuggestionEntry>> suggestionsByDocumentId = const {},
    List<SavedView> savedViews = const [],
  }) : documents = [for (final d in documents) _withMaterializedAncestors(d)],
       tags = List.of(tags),
       views = List.of(savedViews),
       contentByDocumentId = Map.of(contentByDocumentId),
       bytesByDocumentId = {
         for (final e in bytesByDocumentId.entries) e.key: List.of(e.value),
       },
       _suggestionsByDocumentId = {
         for (final e in suggestionsByDocumentId.entries)
           e.key: List.of(e.value),
       };

  final List<DocumentSummary> documents;
  final List<String> tags;

  /// Extracted text keyed by document id (unit-level stand-in for repo content).
  final Map<String, String> contentByDocumentId;

  /// Raw bytes keyed by document id (unit-level stand-in for the blob store).
  final Map<String, List<int>> bytesByDocumentId;

  /// The suggestion returned by [suggestMetadata] (auto-suggest assertion).
  final SuggestionPlan? suggestion;

  /// Pending/applied suggestion rows keyed by document id (review UI fake).
  final Map<String, List<SuggestionEntry>> _suggestionsByDocumentId;

  /// How many times [reindex] has been requested (startup wiring assertion).
  int reindexCount = 0;

  /// How many times [listDocuments] has been called (refresh assertion).
  int listCount = 0;

  /// How many times [setTags] has been called (tag-edit assertion).
  int setTagsCount = 0;

  /// The most recent tags passed to [setTags] (tag-edit assertion).
  List<String>? lastSetTags;

  /// How many times [updateTitle] has been called (rename assertion).
  int updateTitleCount = 0;

  /// The most recent title passed to [updateTitle] (rename assertion).
  String? lastTitle;

  /// How many times [completeSuggestionPoll] has been called (poll assertion).
  int completedPollCount = 0;

  /// The (id, kind) pairs passed to [completeSuggestionPoll] (poll assertion).
  final List<(String, SuggestionKind)> completedPolls = [];

  /// How many times [suggestMetadata] has been called (auto-suggest assertion).
  int suggestCount = 0;

  /// How many times [suggestTitle] has been called (detail wand assertion).
  int suggestTitleCount = 0;

  /// How many times [suggestTags] has been called (detail button assertion).
  int suggestTagsCount = 0;

  /// How many times [reorganizeOne] has been called (detail-button assertion).
  int reorganizeOneCount = 0;

  /// How many times [delete] has been called (bulk-delete assertion).
  int deleteCount = 0;

  /// The ids passed to [delete] (bulk-delete assertion).
  final List<String> deletedIds = [];

  /// The most recent `add` tags passed to [bulkTags] (bulk-tag assertion).
  final List<List<String>> bulkAdds = [];

  /// The most recent `remove` tags passed to [bulkTags] (bulk-tag assertion).
  final List<List<String>> bulkRemoves = [];

  /// The ids passed to the most recent [bulkTags] call (bulk-tag assertion).
  final List<String> bulkTagIds = [];

  /// Saved views seeded for tests and mutated by [saveView]/[deleteSavedView].
  final List<SavedView> views;

  /// Counts of [saveView]/[deleteSavedView] calls (view assertion).
  int savedViewWrites = 0;
  int savedViewDeletes = 0;

  DocumentSummary _byId(String id) => documents.firstWhere(
    (d) => d.id == id,
    orElse: () => throw StateError('document $id not found'),
  );

  @override
  Future<List<DocumentSummary>> listDocuments() async {
    listCount++;
    return List.of(documents);
  }

  @override
  Future<DocumentSummary> getDocument(String id) async => _byId(id);

  @override
  Future<String?> getContent(String id) async => contentByDocumentId[id];

  @override
  Future<List<int>> readBytes(String id) async =>
      List.of(bytesByDocumentId[id] ?? const []);

  @override
  Future<void> setTags(String id, List<String> nextTags) async {
    setTagsCount++;
    lastSetTags = List.of(nextTags);
    final index = documents.indexWhere((d) => d.id == id);
    if (index < 0) throw StateError('document $id not found');
    final doc = documents[index];
    documents[index] = _copy(
      doc,
      tags: expandTagAncestors(nextTags).toList(),
      // A manual tag edit marks the document so the auto-suggest button won't
      // clobber the user's assignment (companion storage task).
      extra: {...doc.extra, 'tags_manual': 'true'},
    );
  }

  @override
  Future<void> updateTitle(String id, String title) async {
    updateTitleCount++;
    lastTitle = title;
    final index = documents.indexWhere((d) => d.id == id);
    if (index < 0) throw StateError('document $id not found');
    final doc = documents[index];
    documents[index] = _copy(
      doc,
      title: title,
      // A manual rename marks the document so the auto-suggest button won't
      // clobber the user's title (companion storage task).
      extra: {...doc.extra, 'title_manual': 'true'},
    );
  }

  @override
  Future<SuggestionPlan> suggestMetadata(String id) async {
    suggestCount++;
    _byId(id); // Throw if the id is unknown, mirroring the repository.
    final plan = suggestion ?? const SuggestionPlan(title: null, tags: []);
    return SuggestionPlan(title: plan.title, tags: List.of(plan.tags));
  }

  @override
  Future<SuggestionPlan> reorganizeOne(String id) async {
    reorganizeOneCount++;
    final doc = _byId(id);
    final plan = suggestion ?? const SuggestionPlan(title: null, tags: []);
    // Mirror the core's manual-edit contract: apply only what the user has not
    // explicitly set by hand.
    if (!doc.tagsManuallyEdited && plan.tags.isNotEmpty) {
      await setTags(id, List.of(plan.tags));
    }
    if (!doc.titleManuallyEdited &&
        plan.title != null &&
        plan.title!.trim().isNotEmpty) {
      await updateTitle(id, plan.title!.trim());
    }
    return SuggestionPlan(title: plan.title, tags: List.of(plan.tags));
  }

  /// The split "Suggest title" action. Always applies the suggestion (manual-
  /// flag gating removed), stores alternatives including the old title, and
  /// returns the outcome so the caller can show the correct snackbar.
  @override
  Future<SuggestionPlan> suggestTitle(String id) async {
    suggestTitleCount++;
    final doc = _byId(id);
    final plan = suggestion ?? const SuggestionPlan(title: null, tags: []);
    final preTitle = doc.title;
    // Always apply the suggestion (no manual-flag gating).
    String? appliedTitle;
    SuggestOutcome outcome;
    if (plan.title != null && plan.title!.trim().isNotEmpty) {
      final trimmed = plan.title!.trim();
      if (trimmed == preTitle) {
        appliedTitle = preTitle;
        outcome = SuggestOutcome(
          status: 'AlreadyCurrent',
          storedPending: BigInt.zero,
        );
      } else {
        appliedTitle = trimmed;
        await updateTitle(id, trimmed);
        outcome = SuggestOutcome(
          status: 'Applied',
          storedPending: BigInt.from(3),
        );
      }
    } else {
      outcome = SuggestOutcome(
        status: 'NoSuggestion',
        storedPending: BigInt.zero,
      );
    }
    return SuggestionPlan(title: appliedTitle, tags: [], outcome: outcome);
  }

  /// The split "Suggest tags" action. Always applies (no gating), stores
  /// alternatives, and returns the outcome.
  @override
  Future<SuggestionPlan> suggestTags(String id) async {
    suggestTagsCount++;
    final doc = _byId(id);
    final plan = suggestion ?? const SuggestionPlan(title: null, tags: []);
    // Always apply the suggestion (no manual-flag gating).
    if (plan.tags.isNotEmpty) {
      await setTags(id, List.of(plan.tags));
    }
    final outcome = plan.tags.isNotEmpty
        ? SuggestOutcome(
            status: doc.tags == plan.tags ? 'AlreadyCurrent' : 'Applied',
            storedPending: BigInt.from(2),
          )
        : SuggestOutcome(status: 'NoSuggestion', storedPending: BigInt.zero);
    return SuggestionPlan(title: null, tags: plan.tags, outcome: outcome);
  }

  /// Permanently remove a document (metadata, raw bytes, extracted content)
  /// from the fake's in-memory state.
  @override
  Future<void> delete(String id) async {
    deleteCount++;
    deletedIds.add(id);
    documents.removeWhere((d) => d.id == id);
    bytesByDocumentId.remove(id);
    contentByDocumentId.remove(id);
    _suggestionsByDocumentId.remove(id);
  }

  // --- suggestion review ------------------------------------------------

  @override
  Future<List<SuggestionEntry>> listSuggestions(String id) async {
    _byId(id);
    return List.of(_suggestionsByDocumentId[id] ?? const []);
  }

  @override
  Future<void> applySuggestion(String id, String suggestionId) async {
    final all = List.of(_suggestionsByDocumentId[id] ?? const []);
    final chosen = all.firstWhere(
      (s) => s.id == suggestionId,
      orElse: () => throw StateError('suggestion $suggestionId not found'),
    );
    if (chosen.kind == SuggestionKind.tags) {
      await setTags(id, chosen.tags);
    } else if (chosen.title != null) {
      await updateTitle(id, chosen.title!);
    }
    // Dismiss every other pending suggestion of the same kind.
    final next = <SuggestionEntry>[
      for (final s in all)
        if (s.id == chosen.id)
          SuggestionEntry(
            id: s.id,
            documentId: s.documentId,
            kind: s.kind,
            title: s.title,
            tags: s.tags,
            rank: s.rank,
            source: s.source,
            status: SuggestionStatus.applied,
          )
        else if (s.kind == chosen.kind)
          SuggestionEntry(
            id: s.id,
            documentId: s.documentId,
            kind: s.kind,
            title: s.title,
            tags: s.tags,
            rank: s.rank,
            source: s.source,
            status: SuggestionStatus.dismissed,
          )
        else
          s,
    ];
    _suggestionsByDocumentId[id] = next;
  }

  @override
  Future<void> confirmCurrent(String id, SuggestionKind kind) async {
    final all = List.of(_suggestionsByDocumentId[id] ?? const []);
    _suggestionsByDocumentId[id] = [
      for (final s in all)
        if (s.kind == kind && s.status == SuggestionStatus.pending)
          SuggestionEntry(
            id: s.id,
            documentId: s.documentId,
            kind: s.kind,
            title: s.title,
            tags: s.tags,
            rank: s.rank,
            source: s.source,
            status: SuggestionStatus.dismissed,
          )
        else
          s,
    ];
  }

  @override
  Future<void> dismissSuggestion(String id, String suggestionId) async {
    final all = List.of(_suggestionsByDocumentId[id] ?? const []);
    _suggestionsByDocumentId[id] = [
      for (final s in all)
        if (s.id == suggestionId)
          SuggestionEntry(
            id: s.id,
            documentId: s.documentId,
            kind: s.kind,
            title: s.title,
            tags: s.tags,
            rank: s.rank,
            source: s.source,
            status: SuggestionStatus.dismissed,
          )
        else
          s,
    ];
  }

  @override
  Future<void> resetSuggestionFeedback() async {
    _suggestionsByDocumentId.clear();
  }

  @override
  Future<int> completeSuggestionPoll(String id, SuggestionKind kind) async {
    _byId(id); // Throw if the id is unknown, mirroring the repository.
    completedPollCount++;
    completedPolls.add((id, kind));
    final all = _suggestionsByDocumentId[id] ?? const [];
    var dismissedCount = 0;
    final next = <SuggestionEntry>[
      for (final s in all)
        if (s.kind == kind && s.status != SuggestionStatus.dismissed)
          SuggestionEntry(
            id: s.id,
            documentId: s.documentId,
            kind: s.kind,
            title: s.title,
            tags: s.tags,
            rank: s.rank,
            source: s.source,
            status: SuggestionStatus.dismissed,
          )
        else
          s,
    ];
    // Count dismissals (rows that were not already dismissed).
    for (final s in all) {
      if (s.kind == kind && s.status != SuggestionStatus.dismissed) {
        dismissedCount++;
      }
    }
    _suggestionsByDocumentId[id] = next;
    return dismissedCount;
  }

  /// Batch tag edit: merge the `add`/`remove` sets into every listed document,
  /// mirroring the repository's semantics (existing tags preserved, adds
  /// appended without duplicates, removes stripped) and recording the batches
  /// for test assertions.
  @override
  Future<void> bulkTags(
    Iterable<String> ids, {
    List<String> add = const [],
    List<String> remove = const [],
  }) async {
    final adds = add.map((t) => t.trim()).where((t) => t.isNotEmpty).toSet();
    final removes = remove
        .map((t) => t.trim())
        .where((t) => t.isNotEmpty)
        .toSet();
    if (adds.isEmpty && removes.isEmpty) return;
    bulkAdds.add(List.of(adds));
    bulkRemoves.add(List.of(removes));
    bulkTagIds.addAll(ids);
    for (final id in ids) {
      final index = documents.indexWhere((d) => d.id == id);
      if (index < 0) continue; // A deleted document is silently skipped.
      final doc = documents[index];
      final next = List<String>.of(doc.tags)
        ..addAll(adds.where((t) => !doc.tags.contains(t)))
        ..removeWhere(removes.contains);
      documents[index] = _copy(
        doc,
        tags: expandTagAncestors(next).toList(),
        // A bulk tag edit is still a *user* tag edit: mark it so auto-suggest
        // won't clobber the assignment (same contract as the repository).
        extra: {...doc.extra, 'tags_manual': 'true'},
      );
    }
  }

  /// Batch delete: remove every listed document (see [delete]).
  @override
  Future<void> bulkDelete(Iterable<String> ids) async {
    for (final id in ids) {
      if (documents.any((d) => d.id == id)) await delete(id);
    }
  }

  DocumentSummary _copy(
    DocumentSummary src, {
    String? title,
    List<String>? tags,
    Map<String, String>? extra,
  }) => DocumentSummary(
    id: src.id,
    title: title ?? src.title,
    snippet: src.snippet,
    tags: tags ?? List.of(src.tags),
    mimeType: src.mimeType,
    originalName: src.originalName,
    extra: extra ?? src.extra,
    sizeBytes: src.sizeBytes,
    createdAtMs: src.createdAtMs,
    updatedAtMs: src.updatedAtMs,
  );

  @override
  Future<List<String>> listTags() async => List.of(tags);

  @override
  Future<List<SavedView>> listSavedViews() async => List.of(views);

  @override
  Future<void> saveView(String name, List<String> tags) async {
    savedViewWrites++;
    final trimmed = name.trim();
    final view = SavedView(name: trimmed, tags: [...tags]..sort());
    final i = views.indexWhere((v) => v.name == trimmed);
    if (i >= 0) {
      views[i] = view;
    } else {
      views.add(view);
    }
  }

  @override
  Future<void> deleteSavedView(String name) async {
    savedViewDeletes++;
    views.removeWhere((v) => v.name == name);
  }

  @override
  Future<void> reindex() async {
    reindexCount++;
  }

  @override
  Future<String?> libraryFilePath(String id) async => null;
}
