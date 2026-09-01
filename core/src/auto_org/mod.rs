//! Automatic document organization pipeline.
//!
//! **Classic-ML first:** the primary implementation is a deterministic, offline,
//! non-generative path. A generative LLM is only an optional upgrade, gated on
//! the user enabling an AI provider ([`crate::ai`]).
//!
//! When a file is ingested, [`DeterministicOrganizer::organize`] runs:
//!
//! 1. **Tagging** — unsupervised, no LLM: TF-IDF over the corpus, then
//!    (a) k-means clustering to surface emergent tag/topic groups ([`cluster`]),
//!    and (b) k-NN tag reuse against already-tagged documents ([`knn`]).
//! 2. **Placement** — deterministic: map predicted tags/topics to hierarchy
//!    paths via user-editable rules/templates ([`rules`]).
//! 3. **Renaming** — two tiers: (a) deterministic from extracted
//!    keywords/entities + metadata via template ([`keywords`]); (b) LLM-generated
//!    filename only when a generative provider is enabled ([`generative`]).
//! 4. **De-duplication** — MinHash/LSH to avoid redundant copies ([`minhash`]).
//!
//! The deterministic path has **zero** dependency on the LLM layer: only
//! [`generative`] imports `crate::ai`. Auto-organization is optional per file
//! (the caller decides whether to call `organize` and which of the resulting
//! [`OrgPlan`] suggestions to apply) and reversible (suggestions are returned as
//! data; applying them is a separate, explicit step).

pub mod cluster;
pub mod config;
pub mod generative;
pub mod keywords;
pub mod knn;
pub mod minhash;
pub mod organizer;
pub mod rules;
pub mod text;

pub use config::{FilenameSource, OrgConfig, OrgPlan};
pub use generative::{apply_generated, generate_filename};
pub use organizer::{Corpus, CorpusDoc, DeterministicOrganizer};
pub use rules::{MatchKind, PlacementRule, RuleSet};

#[cfg(test)]
mod tests;
