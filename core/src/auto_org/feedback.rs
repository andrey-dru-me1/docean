//! Feedback-weighted preference model.
//!
//! The "Basic" learning mode: every time the user reviews a suggestion (keeps
//! the applied one, switches to another, or types their own title/tag), the
//! review flow records a per-term accept/reject event (see
//! [`crate::domain::SuggestionFeedback`]). This module aggregates those events
//! into a small, on-device [`PreferenceModel`] that re-ranks future title and
//! tag suggestions toward the terms the user has shown a preference for.
//!
//! Design goals (see also `plans/suggestions-review-and-learning.md`):
//!
//! * **Tiny footprint** — the model is a pure function of an aggregate table
//!   (`feedback_stats`), so there is no separate serialized state to corrupt or
//!   migrate. RAM is a single `HashMap` of a few thousand terms, built lazily.
//! * **Deterministic & inspectable** — scores are a closed-form function of
//!   (accepts, rejects, recency); no hidden weights. Everything is resettable.
//! * **Cold-start neutral** — a term with no evidence scores exactly `1.0`
//!   (multiply-through identity), so before any feedback the pipeline behaves
//!   exactly as today.
//! * **Off mode** — when [`LearningMode::Off`] is set, the model returns `1.0`
//!   for every term (no recording, no re-ranking), and the reviewer is
//!   instructed not to write feedback rows.
//!
//! The "Advanced" online-classifier phase is intentionally NOT implemented
//! here; [`LearningMode`] is a closed enum so `Off`/`Basic` are stable while a
//! future `Advanced` variant (online SGD over TF-IDF vectors) can be added
//! behind the same settings surface without UI churn.

use std::collections::HashMap;

use crate::domain::{FeedbackStats, SuggestionKind};

/// How strongly an accepted/rejected event moves the score, per weighted unit.
const ACCEPT_GAIN: f64 = 0.35;
const REJECT_PENALTY: f64 = 0.30;

/// Score clamp so a single term can never wipe out a suggestion outright.
const MIN_SCORE: f64 = 0.25;
const MAX_SCORE: f64 = 4.0;

/// Per-suggestion-type learning toggle.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum LearningMode {
    /// Do not record feedback and do not re-rank suggestions.
    Off,
    /// Feedback-weighted per-term preference model (default).
    #[default]
    Basic,
}

impl LearningMode {
    /// Whether suggestions should be re-ranked by learned preferences.
    pub fn is_enabled(self) -> bool {
        matches!(self, LearningMode::Basic)
    }

    /// Whether reviewing a suggestion should record feedback events at all.
    pub fn records_feedback(self) -> bool {
        matches!(self, LearningMode::Basic)
    }
}

/// The aggregate evidence for one term across the whole library.
#[derive(Debug, Clone, Copy, Default)]
struct TermEvidence {
    accepts: f64,
    rejects: f64,
}

/// The on-device preference model: a map of term → accumulated evidence.
///
/// Built from the repository's `feedback_stats` aggregation; a pure data
/// carry-over from one `organize` run to the next with no other state.
#[derive(Debug, Clone, Default)]
pub struct PreferenceModel {
    /// SuggestionKind -> context -> term -> evidence.
    tags: HashMap<String, TermEvidence>,
    titles: HashMap<String, TermEvidence>,
}

impl PreferenceModel {
    pub fn new(off: bool) -> Self {
        if off {
            // Keeps the map empty so every lookup is a neutral 1.0 — same as
            // `LearningMode::Off` without threading the flag through every call.
            Self::default()
        } else {
            Self::default()
        }
    }

    /// Build the model from already-aggregated per-term stats.
    pub fn from_stats(
        tag_stats: HashMap<String, FeedbackStats>,
        title_stats: HashMap<String, FeedbackStats>,
    ) -> Self {
        Self {
            tags: tag_stats
                .into_iter()
                .map(|(term, s)| {
                    (
                        term,
                        TermEvidence {
                            accepts: s.accepts,
                            rejects: s.rejects,
                        },
                    )
                })
                .collect(),
            titles: title_stats
                .into_iter()
                .map(|(term, s)| {
                    (
                        term,
                        TermEvidence {
                            accepts: s.accepts,
                            rejects: s.rejects,
                        },
                    )
                })
                .collect(),
        }
    }

    /// An empty model (no feedback applied). Convenience for code paths that
    /// run before any learning exists (or in `LearningMode::Off`).
    pub fn neutral() -> Self {
        Self::default()
    }

    /// The preference score for a single term in a suggestion kind.
    ///
    /// Returns `1.0` for unknown terms (neutral). Scores are clamped to
    /// [`MIN_SCORE`]..=[`MAX_SCORE`] so a single strongly-rejected term can't
    /// fully remove a suggestion and a strongly-accepted one can't dominate
    /// the ranking forever.
    pub fn score(&self, kind: SuggestionKind, term: &str) -> f64 {
        let evidence = match kind {
            SuggestionKind::Tags => self.tags.get(term),
            SuggestionKind::Title => self.titles.get(term),
        };
        match evidence {
            None => 1.0,
            Some(e) if e.accepts == 0.0 && e.rejects == 0.0 => 1.0,
            Some(e) => {
                let s = 1.0 + ACCEPT_GAIN * e.accepts - REJECT_PENALTY * e.rejects;
                s.clamp(MIN_SCORE, MAX_SCORE)
            }
        }
    }

    /// Re-rank a list of tag candidates (each `(term, base_weight)`) by
    /// preference score, stable-sorting by `score * base_weight` descending.
    ///
    /// Neighbor/cluster votes already carry a vote weight; multiplying by the
    /// preference score keeps the deterministic ordering intact when the model
    /// is neutral while letting accepted terms float up.
    pub fn rerank_tags(&self, candidates: Vec<(String, f64)>) -> Vec<(String, f64)> {
        let mut out: Vec<(String, f64)> = candidates
            .into_iter()
            .map(|(term, weight)| {
                let scored = weight * self.score(SuggestionKind::Tags, &term);
                (term, scored)
            })
            .collect();
        out.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal));
        out
    }

    /// Re-rank title candidates (plain strings) by preference score descending,
    /// stable. Unknown titles are all `1.0` so the deterministic template order
    /// is preserved when there is no learned signal.
    pub fn rerank_titles(&self, candidates: Vec<String>) -> Vec<String> {
        let mut out: Vec<(String, f64)> = candidates
            .into_iter()
            .map(|title| {
                let score = self.score(SuggestionKind::Title, &title);
                (title, score)
            })
            .collect();
        out.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal));
        out.into_iter().map(|(title, _)| title).collect()
    }

    /// Whether the model is empty (no learned evidence). Used by callers that
    /// want to skip re-ranking entirely for a tiny perf win.
    pub fn is_empty(&self) -> bool {
        self.tags.is_empty() && self.titles.is_empty()
    }

    /// The number of learned terms (test assertions).
    pub fn len(&self) -> usize {
        self.tags.len() + self.titles.len()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn stats(accepts: f64, rejects: f64) -> FeedbackStats {
        FeedbackStats { accepts, rejects }
    }

    #[test]
    fn neutral_model_scores_everything_1() {
        let model = PreferenceModel::neutral();
        assert_eq!(model.score(SuggestionKind::Tags, "invoice"), 1.0);
        assert_eq!(model.score(SuggestionKind::Title, "quarterly-report"), 1.0);
        assert!(model.is_empty());
    }

    #[test]
    fn accepts_boost_rejects_demote_and_clamp() {
        let mut tags = HashMap::new();
        tags.insert("invoice".to_owned(), stats(3.0, 0.0));
        tags.insert("tax".to_owned(), stats(0.0, 10.0));
        tags.insert("overboosted".to_owned(), stats(100.0, 0.0));
        let model = PreferenceModel::from_stats(tags, HashMap::new());

        assert!(
            model.score(SuggestionKind::Tags, "invoice") > 1.0,
            "accepted term should be boosted"
        );
        assert!(
            model.score(SuggestionKind::Tags, "tax") < 1.0,
            "rejected term should be demoted"
        );
        assert_eq!(model.score(SuggestionKind::Tags, "overboosted"), MAX_SCORE);
        assert_eq!(model.score(SuggestionKind::Tags, "tax"), MIN_SCORE);
    }

    #[test]
    fn rerank_tags_moves_accepted_terms_first() {
        let mut tags = HashMap::new();
        tags.insert("fav".to_owned(), stats(5.0, 0.0));
        let model = PreferenceModel::from_stats(tags, HashMap::new());

        let candidates = vec![
            ("plain".to_owned(), 1.0),
            ("fav".to_owned(), 0.5),
            ("other".to_owned(), 1.0),
        ];
        let ranked = model.rerank_tags(candidates);
        assert_eq!(ranked[0].0, "fav", "accepted term should rank first");
    }

    #[test]
    fn rerank_titles_preserves_order_without_signal() {
        let model = PreferenceModel::neutral();
        let titles = vec!["a-t-b".to_owned(), "b-t-a".to_owned(), "c".to_owned()];
        assert_eq!(model.rerank_titles(titles.clone()), titles);
    }

    #[test]
    fn off_mode_is_neutral_and_empty() {
        let model = PreferenceModel::new(true);
        assert!(model.is_empty());
        assert_eq!(model.score(SuggestionKind::Tags, "anything"), 1.0);
    }

    #[test]
    fn learning_mode_defaults_to_basic_and_records() {
        assert!(LearningMode::default().is_enabled());
        assert!(LearningMode::default().records_feedback());
        assert!(!LearningMode::Off.is_enabled());
    }
}
