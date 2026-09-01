//! Tagging and hierarchy.
//!
//! **Boundary:** the rules and operations that organize documents into a folder
//! tree and a tag cloud. Purely a domain-logic layer on top of
//! [`crate::storage`]; no additional external crates are expected.

use std::collections::BTreeSet;

use crate::domain::{Document, DocumentId, Tag};
use crate::storage::StorageError;

/// Errors returned by taxonomy operations.
#[derive(Debug, thiserror::Error)]
pub enum TaxonomyError {
    #[error("cycle detected while moving {0} under {1}")]
    Cycle(DocumentId, DocumentId),
    #[error(transparent)]
    Storage(#[from] StorageError),
}

/// Interface for the tagging & hierarchy service.
pub trait Taxonomy {
    /// Move a node under a new parent, rejecting moves that would create a cycle.
    fn move_node(
        &mut self,
        node: DocumentId,
        new_parent: Option<DocumentId>,
    ) -> Result<(), TaxonomyError>;

    fn tag(
        &mut self,
        doc: DocumentId,
        tags: impl IntoIterator<Item = Tag>,
    ) -> Result<(), TaxonomyError>;

    fn untag(&mut self, doc: DocumentId, tag: &str) -> Result<(), TaxonomyError>;

    /// Ancestors from the document up to the root.
    fn ancestors(&self, doc: &DocumentId) -> Result<Vec<DocumentId>, TaxonomyError>;

    /// All descendants (transitive closure) of a folder.
    fn descendants(&self, doc: &DocumentId) -> Result<BTreeSet<DocumentId>, TaxonomyError>;

    fn by_tag(&self, tag: &str) -> Result<Vec<Document>, TaxonomyError>;
}
