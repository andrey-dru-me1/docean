//! Unit tests for the search bridge (exact, semantic, hybrid, filters, and
//! snippet highlighting). All tests exercise the same functions the Flutter UI
//! calls, so the behavior verified here is exactly what the UI sees.

use super::{
    index_document_from_repository, search_index_document, search_query,
    search_reindex_from_repository, search_remove_document, search_set_metadata,
    shared_near_dup_index, HighlightSpan, SearchHitDto, SearchMode, SearchRequestDto,
};

fn index_doc(id: &str, text: &str, tags: &[&str]) {
    let _ = search_index_document(id.to_owned(), text.to_owned());
    search_set_metadata(id.to_owned(), tags.iter().map(|s| s.to_string()).collect());
}

fn search(text: &str, mode: SearchMode) -> Vec<SearchHitDto> {
    search_query(SearchRequestDto {
        text: text.to_owned(),
        mode,
        tags: vec![],
        limit: None,
    })
}

fn find<'a>(hits: &'a [SearchHitDto], id: &str) -> Option<&'a SearchHitDto> {
    hits.iter().find(|h| h.document_id == id)
}

#[test]
fn exact_search_returns_matching_snippets_with_highlights() {
    index_doc(
        "t1_a",
        "The quick brown fox jumps over the lazy dog.",
        &["animal"],
    );
    index_doc(
        "t1_b",
        "Rust ownership moves values without copying.",
        &["code"],
    );
    index_doc("t1_c", "A quick run through the park.", &[]);

    let hits = search("quick", SearchMode::Exact);
    assert_eq!(hits.len(), 2, "two docs mention 'quick'");
    let a = find(&hits, "t1_a").expect("doc t1_a should match");
    assert!(a.score > 0.0);
    assert!(!a.highlights.is_empty(), "snippet should be highlighted");
    let span = a.highlights[0];
    assert_eq!(&a.snippet[span.start..span.end], "quick");
}

#[test]
fn exact_search_is_term_based_and_empty_query_returns_nothing() {
    index_doc("t2_a", "The rain in Spain falls mainly on the plain.", &[]);

    assert!(search("", SearchMode::Exact).is_empty());
    let no = search("zzz", SearchMode::Exact);
    assert!(no.is_empty());
}

#[test]
fn semantic_search_finds_rephrased_text_offline() {
    index_doc(
        "t3_a",
        "The company's annual revenue increased by twenty percent.",
        &[],
    );
    index_doc(
        "t3_b",
        "Birdwatching requires patience and binoculars.",
        &[],
    );

    let hits = search("yearly income grew 20%", SearchMode::Semantic);
    assert!(
        find(&hits, "t3_a").is_some(),
        "semantic search should rank the revenue doc first for a rephrased query"
    );
    // The unrelated doc should not outrank the relevant one.
    let a_score = find(&hits, "t3_a").map(|h| h.score).unwrap_or(0.0);
    let b_score = find(&hits, "t3_b").map(|h| h.score).unwrap_or(0.0);
    assert!(a_score > b_score, "a={a_score} should beat b={b_score}");
}

#[test]
fn hybrid_search_combines_and_deduplicates() {
    index_doc(
        "t4_a",
        "Mount Everest is the tallest mountain in the world.",
        &[],
    );
    index_doc(
        "t4_b",
        "The tallest peak, Everest, stands in the Himalayas.",
        &[],
    );

    let hits = search("tallest mountain", SearchMode::Hybrid);
    assert!(
        find(&hits, "t4_a").is_some() && find(&hits, "t4_b").is_some(),
        "hybrid returns both related docs"
    );
}

#[test]
fn every_dto_score_is_relevance_in_0_to_1_for_all_modes() {
    // Repeated keywords push the exact (FTS5) score > 1 under the old
    // `exp(-rank)` mapping; unrelated vocabulary yields negative cosine under
    // the old raw-cosine semantic mapping. Both must land in `[0, 1]` now.
    index_doc("s1_rep", "search search search search search", &[]);
    index_doc("s1_unrelated", "aardvark zephyr quixotic klaxon fjord", &[]);
    index_doc(
        "s1_office",
        "office supplies and the office printer invoice",
        &[],
    );
    index_doc("s1_cookie", "chocolate chip cookie recipe", &[]);

    for mode in [SearchMode::Exact, SearchMode::Semantic, SearchMode::Hybrid] {
        let hits = search("office supplies", mode);
        assert!(
            !hits.is_empty(),
            "mode {mode:?} should return results for 'office supplies'"
        );
        for h in &hits {
            assert!(
                (0.0..=1.0).contains(&h.score),
                "mode {mode:?}: {} has score {} outside [0,1]",
                h.document_id,
                h.score
            );
        }
    }
}

#[test]
fn tag_filters_restrict_results() {
    index_doc(
        "t5_a",
        "Quarterly sales report for Q3.",
        &["finance", "report"],
    );
    index_doc("t5_b", "Product roadmap draft.", &["product"]);
    index_doc("t5_c", "Personal notes on quarterly goals.", &["personal"]);

    let by_tag = search_query(SearchRequestDto {
        text: "quarterly".to_owned(),
        mode: SearchMode::Exact,
        tags: vec!["finance".to_owned()],
        limit: None,
    });
    assert_eq!(by_tag.len(), 1);
    assert_eq!(by_tag[0].document_id, "t5_a");
}

#[test]
fn remove_document_drops_it_from_search_and_metadata() {
    index_doc("t6_a", "Unique phrase: xylophone calendar.", &["x"]);
    assert_eq!(search("xylophone", SearchMode::Exact).len(), 1);

    let _ = search_remove_document("t6_a".to_owned());
    assert!(search("xylophone", SearchMode::Exact).is_empty());
    let filtered = search_query(SearchRequestDto {
        text: "xylophone".to_owned(),
        mode: SearchMode::Exact,
        tags: vec!["x".to_owned()],
        limit: None,
    });
    assert!(filtered.is_empty());
}

#[test]
fn shared_near_dup_index_is_the_instance_the_indexer_writes_to() {
    // The sync layer (`crate::api::sync`) attaches this exact handle so its
    // reconciler can propose related versions. Confirm it observes documents the
    // search bridge indexes — i.e. it is the *same* index instance, not a copy.
    index_doc(
        "t8_origin",
        "algorithmic complexity guarantees amortized logarithmic lookup behavior",
        &[],
    );

    let idx = shared_near_dup_index();
    let matches = idx.lock().unwrap().query(
        "algorithmic complexity guarantees amortized logarithmic lookup behavior and correctness",
        0.5,
    );
    assert!(
        matches.iter().any(|m| m.document_id == "t8_origin"),
        "shared near-dup index should know about bridge-indexed docs: {matches:?}"
    );
}

#[test]
fn highlight_spans_are_case_insensitive_and_byte_aligned() {
    index_doc("t7_a", "Alpha beta Gamma delta.", &[]);
    let hits = search("alpha GAMMA", SearchMode::Exact);
    let a = find(&hits, "t7_a").unwrap();
    let spans: Vec<&HighlightSpan> = a.highlights.iter().collect();
    assert_eq!(spans.len(), 2);
    let wanted = ["alpha", "gamma"];
    for (i, s) in a.highlights.iter().enumerate() {
        let sub = &a.snippet[s.start..s.end];
        // Matching is case-insensitive: the span bounds the original-cased
        // text, so compare in lower case.
        assert_eq!(sub.to_lowercase(), wanted[i]);
    }
    // Spans must be sorted and non-overlapping.
    for w in a.highlights.windows(2) {
        assert!(w[0].end <= w[1].start);
    }
}

// ---------------------------------------------------------------------------
// Search-index wiring: repository <-> in-memory engine
// ---------------------------------------------------------------------------

use crate::api::storage::open_repository;
use crate::domain::{Document, NodeKind};

/// A temp root for a fresh on-disk repository.
fn temp_root(tag: &str) -> std::path::PathBuf {
    use std::time::{SystemTime, UNIX_EPOCH};
    let mut p = std::env::temp_dir();
    p.push(format!(
        "docean-search-wire-{tag}-{}-{}",
        std::process::id(),
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    std::fs::create_dir_all(&p).unwrap();
    p
}

/// Shared point so both wiring tests can build a document directly in a repo.
/// Returns the document id (the content address = SHA-256 of the bytes).
fn put_document(repo: &crate::api::storage::DocumentRepository, title: &str, text: &str) -> String {
    let bytes = text.as_bytes().to_vec();
    let checksum = crate::storage::hash_bytes(&bytes);
    let doc = Document {
        id: checksum.clone(),
        parent_id: None,
        kind: NodeKind::Document,
        title: title.to_owned(),
        mime_type: "text/plain".to_owned(),
        size_bytes: bytes.len() as u64,
        checksum_sha256: checksum.clone(),
        tags: vec!["wired".to_owned()],
        created_at_ms: 1,
        updated_at_ms: 1,
        extra: Default::default(),
    };
    repo.put(doc, bytes).unwrap();
    repo.put_content(checksum.clone(), text.to_owned(), "plain".to_owned())
        .unwrap();
    checksum
}

#[test]
fn index_document_from_repository_wires_a_persisted_doc_into_search() {
    // The ingestion pipeline calls this helper after storing a file; it must
    // make the persisted document immediately searchable (and filterable by the
    // metadata registered alongside it).
    let root = temp_root("single");
    let repo = open_repository(root.display().to_string()).unwrap();
    let id = put_document(
        &repo,
        "Wired Report",
        "unique phrase: quasar inventory plateau",
    );

    index_document_from_repository(&repo, &id).unwrap();

    let hits = search("quasar", SearchMode::Exact);
    let hit = find(&hits, &id).expect("persisted doc should be searchable after wiring");
    assert_eq!(hit.tags, vec!["wired"]);

    let _ = search_remove_document(id);
    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn search_reindex_from_repository_rebuilds_index_from_sqlite() {
    // Simulates app startup: repos are loaded from disk but the in-memory search
    // index is empty. Search must be consistent with the persisted store after a
    // re-index pass seeded from `repo.query` / content / tags.
    let root = temp_root("reindex");
    let repo = open_repository(root.display().to_string()).unwrap();
    let id = put_document(
        &repo,
        "Startup Doc",
        "persisted before launch: eclipse beacon",
    );

    // The search index is empty until re-indexed.
    assert!(search("eclipse", SearchMode::Exact).is_empty());

    search_reindex_from_repository(&repo).unwrap();

    let hits = search("eclipse", SearchMode::Exact);
    let hit = find(&hits, &id).expect("reindex should wire persisted docs into search");
    assert!(!hit.snippet.is_empty());
    assert_eq!(hit.tags, vec!["wired"]);

    let _ = search_remove_document(id);
    let _ = std::fs::remove_dir_all(&root);
}
