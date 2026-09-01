//! k-nearest-neighbor tag reuse over TF-IDF vectors.
//!
//! Tag reuse (1b in the spec): for a newly ingested document, find the existing
//! documents most similar to it and reuse their tags, so the taxonomy grows
//! consistently instead of minting near-duplicate tags.
//!
//! Implemented as cosine-similarity k-NN over TF-IDF vectors rather than the
//! search layer's embedding index because the embedding index is not yet
//! implemented (the [`crate::search::SearchIndex`] trait is an interface only).
//! The signature is deliberately data-agnostic (a sparse weight vector in, a
//! ranked list of ids out) so it can be swapped for embeddings later without
//! changing the calling pipeline.

use std::collections::HashMap;

use crate::auto_org::text::TfIdfModel;

/// A single neighbor with a similarity score in `[0, 1]`.
#[derive(Debug, Clone, PartialEq)]
pub struct Neighbor {
    pub document_id: String,
    pub score: f64,
}

/// A unique tag observation with an accumulated vote weight.
#[derive(Debug, Clone, PartialEq)]
pub struct TagVote {
    pub tag: String,
    pub weight: f64,
}

/// Rank the `candidates` (each identified by id with a TF-IDF vector) by cosine
/// similarity to `query`, returning the top `k` in descending order.
pub fn nearest_neighbors(
    query: &HashMap<String, f64>,
    candidates: &[(String, HashMap<String, f64>)],
    k: usize,
) -> Vec<Neighbor> {
    let mut scored: Vec<Neighbor> = candidates
        .iter()
        .map(|(id, vec)| Neighbor {
            document_id: id.clone(),
            score: TfIdfModel::cosine(query, vec),
        })
        .collect();

    // Stable sort descending by score (ties broken by id for determinism).
    scored.sort_by(|a, b| {
        b.score
            .total_cmp(&a.score)
            .then_with(|| a.document_id.cmp(&b.document_id))
    });

    scored.into_iter().take(k).collect()
}

/// Aggregate tags from a ranked list of neighbors into a score-ordered list of
/// unique tags, where each tag's weight is the sum of its neighbors' similarity
/// scores (a simple weighted vote).
pub fn reuse_tags(
    neighbors: &[Neighbor],
    tags_by_id: &HashMap<String, Vec<String>>,
) -> Vec<TagVote> {
    let mut votes: HashMap<String, f64> = HashMap::new();
    let mut order: Vec<String> = Vec::new();

    for neighbor in neighbors {
        if let Some(tags) = tags_by_id.get(&neighbor.document_id) {
            for tag in tags {
                if !votes.contains_key(tag) {
                    order.push(tag.clone());
                }
                *votes.entry(tag.clone()).or_insert(0.0) += neighbor.score;
            }
        }
    }

    let mut result: Vec<TagVote> = order
        .into_iter()
        .map(|tag| TagVote {
            weight: votes.get(&tag).copied().unwrap_or(0.0),
            tag,
        })
        .collect();
    result.sort_by(|a, b| {
        b.weight
            .total_cmp(&a.weight)
            .then_with(|| a.tag.cmp(&b.tag))
    });
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::auto_org::text::TfIdfModel;

    fn empty() -> HashMap<String, f64> {
        HashMap::new()
    }

    #[test]
    fn nearest_neighbors_rank_by_similarity() {
        let model = TfIdfModel::fit([
            ("a", "invoice office supplies".to_owned()),
            ("b", "invoice receipt office".to_owned()),
            ("c", "chocolate cake recipe".to_owned()),
        ]);
        let query = model.vectorize("office invoice supplies");
        let candidates: Vec<(String, HashMap<String, f64>)> = vec![
            ("a".to_owned(), model.vectorize("invoice office supplies")),
            ("b".to_owned(), model.vectorize("invoice receipt office")),
            ("c".to_owned(), model.vectorize("chocolate cake recipe")),
        ];

        let top = nearest_neighbors(&query, &candidates, 2);
        assert_eq!(top.len(), 2);
        assert_eq!(top[0].document_id, "a");
        assert!(top[0].score >= top[1].score);
    }

    #[test]
    fn reuse_tags_aggregates_weighted_votes() {
        let neighbors = vec![
            Neighbor {
                document_id: "a".to_owned(),
                score: 0.9,
            },
            Neighbor {
                document_id: "b".to_owned(),
                score: 0.6,
            },
        ];
        let mut tags_by_id = HashMap::new();
        tags_by_id.insert(
            "a".to_owned(),
            vec!["invoice".to_owned(), "receipt".to_owned()],
        );
        tags_by_id.insert("b".to_owned(), vec!["receipt".to_owned()]);

        let votes = reuse_tags(&neighbors, &tags_by_id);
        assert_eq!(votes[0].tag, "receipt");
        assert_eq!(votes[0].weight, 1.5);
        assert_eq!(votes[1].tag, "invoice");
        assert_eq!(votes[1].weight, 0.9);
    }

    #[test]
    fn empty_query_yields_zero_scores() {
        let candidates: Vec<(String, HashMap<String, f64>)> = vec![("a".to_owned(), empty())];
        let top = nearest_neighbors(&empty(), &candidates, 1);
        assert_eq!(top[0].score, 0.0);
    }
}
