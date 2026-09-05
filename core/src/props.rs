use std::collections::{BTreeMap, BTreeSet};
use std::io;
use std::path::Path;

use crate::api::storage::DocumentRepository;
use crate::domain::PathAssignment;

// ── Tag parsing ──────────────────────────────────────────────────────────────

/// Parse a property tag `"key:value"` into `(key, value)`.
///
/// Returns `None` when the tag is not a valid property:
/// - zero or more than one `:`
/// - empty key or empty value
/// - key contains characters outside `[a-z0-9_-]`
pub fn parse_property_tag(tag: &str) -> Option<(String, String)> {
    let colon = tag.find(':')?;
    if tag[colon + 1..].contains(':') {
        return None;
    }
    let key = &tag[..colon];
    let value = &tag[colon + 1..];
    if key.is_empty() || value.is_empty() {
        return None;
    }
    if !key
        .bytes()
        .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'_' || b == b'-')
    {
        return None;
    }
    Some((key.to_owned(), value.to_owned()))
}

/// Returns `true` when `tag` is a valid property tag.
pub fn is_property_tag(tag: &str) -> bool {
    parse_property_tag(tag).is_some()
}

/// Extract all property tags from a tag list, preserving original order.
pub fn property_tags(tags: &[String]) -> Vec<(String, String)> {
    tags.iter().filter_map(|t| parse_property_tag(t)).collect()
}

// ── Scope definitions & registry ─────────────────────────────────────────────

#[derive(Debug, Clone, PartialEq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ScopeDef {
    pub name: String,
    pub order: Vec<String>,
    /// Optional parent scope name. `None` means root scope.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub parent: Option<String>,
}

#[derive(Debug, Clone, Default)]
pub struct ScopeRegistry {
    inner: BTreeMap<String, ScopeDef>,
}

impl ScopeRegistry {
    /// Load the registry from `<root>/scopes.json`. Returns an empty registry
    /// when the file is missing or contains invalid JSON — never panics.
    pub fn load(root: &Path) -> Self {
        let data = match std::fs::read_to_string(root.join("scopes.json")) {
            Ok(d) => d,
            Err(_) => return Self::default(),
        };
        let defs: Vec<ScopeDef> = match serde_json::from_str(&data) {
            Ok(d) => d,
            Err(_) => return Self::default(),
        };
        let inner: BTreeMap<String, ScopeDef> = defs
            .into_iter()
            .filter(|d| !d.name.is_empty())
            .map(|d| (d.name.clone(), d))
            .collect();
        Self { inner }
    }

    /// Persist the registry to `<root>/scopes.json`.
    pub fn save(&self, root: &Path) -> io::Result<()> {
        let defs: Vec<&ScopeDef> = self.inner.values().collect();
        let json = serde_json::to_string_pretty(&defs)
            .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?;
        std::fs::write(root.join("scopes.json"), json)
    }

    pub fn get(&self, name: &str) -> Option<ScopeDef> {
        self.inner.get(name).cloned()
    }

    /// Insert or replace a scope definition. Returns an error when the parent
    /// is `Some(name)` and `name` does not exist in the registry, or when
    /// setting the parent would create a cycle (parent is a descendant of
    /// this scope).
    pub fn upsert(&mut self, def: ScopeDef) -> Result<(), String> {
        if def.name.is_empty() {
            return Err("scope name must not be empty".into());
        }
        if let Some(ref parent) = def.parent {
            if !self.inner.contains_key(parent.as_str()) {
                return Err(format!("parent scope '{parent}' does not exist"));
            }
            // Cycle check: walk up from parent and see if we hit def.name
            if self.would_create_cycle(&def.name, parent.as_str()) {
                return Err(format!(
                    "setting parent '{parent}' on scope '{}' would create a cycle",
                    def.name
                ));
            }
        }
        self.inner.insert(def.name.clone(), def);
        Ok(())
    }

    /// All scope definitions sorted by name.
    pub fn list(&self) -> Vec<ScopeDef> {
        self.inner.values().cloned().collect()
    }

    pub fn remove(&mut self, name: &str) {
        // Also reparent any children to None
        let children: Vec<String> = self
            .inner
            .values()
            .filter(|d| d.parent.as_deref() == Some(name))
            .map(|d| d.name.clone())
            .collect();
        for child in &children {
            if let Some(mut def) = self.inner.get_mut(child.as_str()).cloned() {
                def.parent = None;
                self.inner.insert(child.clone(), def);
            }
        }
        self.inner.remove(name);
    }

    /// Walk up from `name`'s ancestors. Returns true if `ancestor_candidate`
    /// is reachable — meaning setting `ancestor_candidate` as parent of `name`
    /// would close a cycle.
    fn would_create_cycle(&self, name: &str, candidate_parent: &str) -> bool {
        let mut current = Some(candidate_parent.to_owned());
        while let Some(ref p) = current {
            if p == name {
                return true;
            }
            current = self.inner.get(p.as_str()).and_then(|d| d.parent.clone());
        }
        false
    }

    /// Walk the parent chain from `name` up to the root, collecting names
    /// root-first. e.g. `[root, mid, name]`.
    pub fn ancestors(&self, name: &str) -> Vec<String> {
        let mut chain = vec![name.to_owned()];
        let mut current = self.inner.get(name).and_then(|d| d.parent.clone());
        while let Some(ref p) = current {
            chain.push(p.clone());
            current = self.inner.get(p.as_str()).and_then(|d| d.parent.clone());
        }
        chain.reverse();
        chain
    }
}

// ── Scope detection ──────────────────────────────────────────────────────────

#[derive(Debug, Clone, PartialEq)]
pub struct ScopeResolution {
    pub scope: String,
    pub chain: Vec<String>,
    pub created: bool,
    pub main_path: String,
}

/// Detect the scope for a document's tag set.
///
/// 1. Explicit `scope:<name>` tag wins — ensure a `ScopeDef` exists (created if
///    needed), return `created = true`.
/// 2. Match known scopes by full coverage; pick the shortest order (most
///    specific), break ties alphabetically.
/// 3. No match → create a new `auto-<n>` scope with the document's property
///    keys sorted alphabetically as order.
pub fn detect_scope(tags: &[String], registry: &mut ScopeRegistry) -> ScopeResolution {
    let props = property_tags(tags);
    let doc_keys: Vec<&str> = props
        .iter()
        .map(|(k, _)| k.as_str())
        .filter(|k| *k != "scope")
        .collect();
    let doc_props: BTreeMap<&str, &str> = props
        .iter()
        .filter(|(k, _)| k.as_str() != "scope")
        .map(|(k, v)| (k.as_str(), v.as_str()))
        .collect();

    // 1. Explicit scope tags. A doc may carry several (one per chain it belongs
    // to); the PRIMARY is the most specific (shortest order, alphabetical tie-
    // break) among the explicitly tagged scopes that are defined. If none of
    // the explicit scopes is defined, create one for the alphabetically-first.
    let explicit: Vec<String> = props
        .iter()
        .filter(|(k, _)| k == "scope")
        .map(|(_, v)| v.clone())
        .collect();
    if !explicit.is_empty() {
        let mut best_def: Option<ScopeDef> = None;
        for name in &explicit {
            if let Some(def) = registry.get(name) {
                let better = match &best_def {
                    None => true,
                    Some(prev) => {
                        def.order.len() < prev.order.len()
                            || (def.order.len() == prev.order.len() && def.name < prev.name)
                    }
                };
                if better {
                    best_def = Some(def);
                }
            }
        }
        if let Some(def) = best_def {
            let chain = registry.ancestors(&def.name);
            let path = main_path_for(&chain, &def.order, tags);
            return ScopeResolution {
                scope: def.name,
                chain,
                created: false,
                main_path: path,
            };
        }
        let mut names = explicit.clone();
        names.sort();
        let scope_name = names[0].clone();
        let mut order: Vec<String> = doc_keys.iter().map(|k| k.to_string()).collect();
        order.sort();
        let def = ScopeDef {
            name: scope_name.clone(),
            order,
            parent: None,
        };
        let chain = vec![scope_name.clone()];
        let path = main_path_for(&chain, &def.order, tags);
        let _ = registry.upsert(def);
        return ScopeResolution {
            scope: scope_name,
            chain,
            created: true,
            main_path: path,
        };
    }

    // 2. Match by full coverage. A scope with an empty `order` defines no
    // hierarchy keys and therefore can never be "fully covered" — it must not
    // absorb every document, so it is ineligible for coverage matching.
    let mut best: Option<ScopeDef> = None;
    for def in registry.list() {
        if def.order.is_empty() {
            continue;
        }
        let covered = def.order.iter().all(|k| doc_props.contains_key(k.as_str()));
        if !covered {
            continue;
        }
        match &best {
            None => best = Some(def.clone()),
            Some(prev) => {
                if def.order.len() < prev.order.len()
                    || (def.order.len() == prev.order.len() && def.name < prev.name)
                {
                    best = Some(def.clone());
                }
            }
        }
    }
    if let Some(def) = best {
        let chain = registry.ancestors(&def.name);
        let path = main_path_for(&chain, &def.order, tags);
        return ScopeResolution {
            scope: def.name,
            chain,
            created: false,
            main_path: path,
        };
    }

    // 3. Auto-create
    let next_n = (1u32..)
        .map(|n| format!("auto-{n}"))
        .find(|name| registry.get(name.as_str()).is_none())
        .unwrap();
    let mut order: Vec<String> = doc_keys.iter().map(|k| k.to_string()).collect();
    order.sort();
    let def = ScopeDef {
        name: next_n.clone(),
        order,
        parent: None,
    };
    let chain = vec![next_n.clone()];
    let path = main_path_for(&chain, &def.order, tags);
    let _ = registry.upsert(def);
    ScopeResolution {
        scope: next_n,
        chain,
        created: true,
        main_path: path,
    }
}

// ── Path building ────────────────────────────────────────────────────────────

/// Sanitize a single path segment: keep `[A-Za-z0-9._ -]`, replace other chars
/// with `_`, collapse consecutive `_`, trim, cap at 60 chars, return `None` when
/// the result is empty after sanitization.
fn sanitize_segment(raw: &str) -> Option<String> {
    let mut out = String::new();
    let mut last: Option<char> = None;
    for ch in raw.chars() {
        let c = if ch.is_ascii_alphanumeric() || ch == '.' || ch == '_' || ch == '-' || ch == ' ' {
            ch
        } else {
            '_'
        };
        if c == '_' && last == Some('_') {
            continue;
        }
        out.push(c);
        last = Some(c);
    }
    let trimmed = out.trim();
    if trimmed.is_empty() {
        return None;
    }
    let t: String = trimmed.to_owned();
    if t.len() > 60 {
        Some(t[..60].to_owned())
    } else {
        Some(t)
    }
}

/// Build the main hierarchy path for a scope chain.
///
/// Path = one segment per ancestor scope name (root→specific), followed by
/// the property value segments of the most specific scope.
///
/// Example: chain `["teaching", "diploma"]`, order `["study-year", "student"]`
/// with matching tags → `/teaching/diploma/2025-2026/Andrey`
pub fn main_path_for(chain: &[String], order: &[String], tags: &[String]) -> String {
    let props = property_tags(tags);
    let map: BTreeMap<&str, &str> = props
        .iter()
        .map(|(k, v)| (k.as_str(), v.as_str()))
        .collect();

    let mut segments: Vec<String> = chain.iter().filter_map(|s| sanitize_segment(s)).collect();

    for key in order {
        if let Some(&val) = map.get(key.as_str()) {
            if let Some(seg) = sanitize_segment(val) {
                segments.push(seg);
            }
        }
    }

    if segments.is_empty() {
        "/".to_owned()
    } else {
        format!("/{}", segments.join("/"))
    }
}

// ── process_document ─────────────────────────────────────────────────────────

/// Process a document: detect (or create) its scope, ensure all ancestor scope
/// tags are present, stamp `extra["main_path"]`, and assign the hierarchy path.
///
/// Idempotent — calling twice produces no additional side effects. Never
/// hard-fails the document; errors are returned as `Err(String)`.
pub fn process_document(repo: &DocumentRepository, id: &str) -> Result<ScopeResolution, String> {
    let doc = repo.get(id.to_owned())?;
    let mut registry = ScopeRegistry::load(repo.root_dir());
    let resolution = detect_scope(&doc.tags, &mut registry);
    if resolution.created {
        let _ = registry.save(repo.root_dir());
    }

    // Compute all scope tags the doc should have: all ancestors + the most
    // specific scope. For now, the primary (most specific) chain is the one
    // returned by detect_scope. Other chains are preserved but not further
    // processed in this wave.
    let mut scope_tags: BTreeSet<String> = doc
        .tags
        .iter()
        .filter(|t| t.starts_with("scope:"))
        .cloned()
        .collect();
    for name in &resolution.chain {
        scope_tags.insert(format!("scope:{name}"));
    }

    let mut doc = doc;
    let mut updated = false;

    // Add any missing scope tags
    for stag in &scope_tags {
        if !doc.tags.contains(stag) {
            doc.tags.push(stag.clone());
            doc.updated_at_ms = crate::api::storage::now_ms();
            updated = true;
        }
    }

    // Stamp main_path if changed
    let current_main_path = doc.extra.get("main_path").cloned().unwrap_or_default();
    if current_main_path != resolution.main_path {
        doc.extra
            .insert("main_path".to_owned(), resolution.main_path.clone());
        doc.updated_at_ms = crate::api::storage::now_ms();
        updated = true;
    }

    if updated {
        let bytes = repo.read_bytes(id.to_owned())?;
        repo.put(doc, bytes)?;
    }

    // Assign the hierarchy path (idempotent upsert + assign)
    let already_assigned = repo
        .paths_of(id.to_owned())?
        .into_iter()
        .any(|p| p.path == resolution.main_path);
    if !already_assigned {
        repo.put_path(resolution.main_path.clone())?;
        repo.assign_path(PathAssignment {
            document_id: id.to_owned(),
            path: resolution.main_path.clone(),
            position: 0,
        })?;
    }

    Ok(resolution)
}

// ── Tests ────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;
    use std::fs;
    use std::time::{SystemTime, UNIX_EPOCH};

    use crate::api::storage::open_repository;
    use crate::domain::{Content, Document, NodeKind};
    use crate::storage::DocumentStore;

    fn temp_root(tag: &str) -> std::path::PathBuf {
        let mut p = std::env::temp_dir();
        p.push(format!(
            "docer-props-{tag}-{}-{}",
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::create_dir_all(&p).unwrap();
        p
    }

    fn seed_doc(
        repo: &crate::api::storage::DocumentRepository,
        id: &str,
        tags: Vec<String>,
        extra: HashMap<String, String>,
    ) {
        let mut store = repo.store().unwrap();
        store
            .put(
                Document {
                    id: id.to_owned(),
                    parent_id: None,
                    kind: NodeKind::Document,
                    title: id.to_owned(),
                    mime_type: "text/plain".to_owned(),
                    size_bytes: 0,
                    checksum_sha256: String::new(),
                    tags,
                    created_at_ms: 1,
                    updated_at_ms: 1,
                    extra,
                },
                b"",
            )
            .unwrap();
        store
            .put_content(&Content {
                document_id: id.to_owned(),
                text: String::new(),
                source: "test".to_owned(),
            })
            .unwrap();
    }

    // ── parse_property_tag ──────────────────────────────────────────────

    #[test]
    fn parse_property_tag_happy() {
        assert_eq!(
            parse_property_tag("student:Alice"),
            Some(("student".to_owned(), "Alice".to_owned()))
        );
        assert_eq!(
            parse_property_tag("scope:finance"),
            Some(("scope".to_owned(), "finance".to_owned()))
        );
        assert_eq!(
            parse_property_tag("year:2026"),
            Some(("year".to_owned(), "2026".to_owned()))
        );
    }

    #[test]
    fn parse_property_tag_rejects_plain() {
        assert_eq!(parse_property_tag("plain_tag"), None);
    }

    #[test]
    fn parse_property_tag_rejects_multiple_colons() {
        assert_eq!(parse_property_tag("a:b:c"), None);
    }

    #[test]
    fn parse_property_tag_rejects_empty_key() {
        assert_eq!(parse_property_tag(":value"), None);
    }

    #[test]
    fn parse_property_tag_rejects_empty_value() {
        assert_eq!(parse_property_tag("key:"), None);
    }

    #[test]
    fn parse_property_tag_rejects_uppercase_key() {
        assert_eq!(parse_property_tag("STUDENT:Alice"), None);
    }

    #[test]
    fn parse_property_tag_rejects_space_in_key() {
        assert_eq!(parse_property_tag("a b:x"), None);
    }

    #[test]
    fn parse_property_tag_hyphen_and_underscore_ok() {
        assert_eq!(
            parse_property_tag("my-key:val"),
            Some(("my-key".to_owned(), "val".to_owned()))
        );
        assert_eq!(
            parse_property_tag("my_key:val"),
            Some(("my_key".to_owned(), "val".to_owned()))
        );
    }

    // ── property_tags ───────────────────────────────────────────────────

    #[test]
    fn property_tags_extracts_and_preserves_order() {
        let tags: Vec<String> = vec![
            "plain".to_owned(),
            "a:1".to_owned(),
            "b:2".to_owned(),
            "scope:x".to_owned(),
        ];
        assert_eq!(
            property_tags(&tags),
            vec![
                ("a".to_owned(), "1".to_owned()),
                ("b".to_owned(), "2".to_owned()),
                ("scope".to_owned(), "x".to_owned()),
            ]
        );
    }

    // ── ScopeRegistry ───────────────────────────────────────────────────

    #[test]
    fn registry_load_missing_file() {
        let root = temp_root("reg-missing");
        let reg = ScopeRegistry::load(&root);
        assert!(reg.list().is_empty());
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn registry_load_corrupt_json() {
        let root = temp_root("reg-corrupt");
        fs::write(root.join("scopes.json"), "{ bad json!!").unwrap();
        let reg = ScopeRegistry::load(&root);
        assert!(reg.list().is_empty());
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn registry_save_load_roundtrip() {
        let root = temp_root("reg-roundtrip");
        {
            let mut reg = ScopeRegistry::default();
            reg.upsert(ScopeDef {
                name: "finance".to_owned(),
                order: vec!["year".to_owned(), "type".to_owned()],
                parent: None,
            })
            .unwrap();
            reg.upsert(ScopeDef {
                name: "student".to_owned(),
                order: vec!["subject".to_owned()],
                parent: None,
            })
            .unwrap();
            reg.save(&root).unwrap();
        }
        let loaded = ScopeRegistry::load(&root);
        assert_eq!(loaded.list().len(), 2);
        assert_eq!(
            loaded.get("finance").unwrap().order,
            vec!["year".to_owned(), "type".to_owned()]
        );
        assert_eq!(
            loaded.get("student").unwrap().order,
            vec!["subject".to_owned()]
        );
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn registry_upsert_get_remove() {
        let mut reg = ScopeRegistry::default();
        assert!(reg.get("x").is_none());
        reg.upsert(ScopeDef {
            name: "x".to_owned(),
            order: vec![],
            parent: None,
        })
        .unwrap();
        assert!(reg.get("x").is_some());
        reg.remove("x");
        assert!(reg.get("x").is_none());
    }

    #[test]
    fn registry_upsert_parent_must_exist() {
        let mut reg = ScopeRegistry::default();
        let res = reg.upsert(ScopeDef {
            name: "child".to_owned(),
            order: vec![],
            parent: Some("nonexistent".to_owned()),
        });
        assert!(res.is_err());
        assert!(res.unwrap_err().contains("does not exist"));
    }

    #[test]
    fn registry_upsert_rejects_cycle() {
        let mut reg = ScopeRegistry::default();
        reg.upsert(ScopeDef {
            name: "a".to_owned(),
            order: vec![],
            parent: None,
        })
        .unwrap();
        reg.upsert(ScopeDef {
            name: "b".to_owned(),
            order: vec![],
            parent: Some("a".to_owned()),
        })
        .unwrap();
        // a→b, now try b→a: cycle
        let res = reg.upsert(ScopeDef {
            name: "a".to_owned(),
            order: vec![],
            parent: Some("b".to_owned()),
        });
        assert!(res.is_err());
        assert!(res.unwrap_err().contains("cycle"));
    }

    #[test]
    fn registry_ancestors() {
        let mut reg = ScopeRegistry::default();
        reg.upsert(ScopeDef {
            name: "root".to_owned(),
            order: vec![],
            parent: None,
        })
        .unwrap();
        reg.upsert(ScopeDef {
            name: "mid".to_owned(),
            order: vec![],
            parent: Some("root".to_owned()),
        })
        .unwrap();
        reg.upsert(ScopeDef {
            name: "leaf".to_owned(),
            order: vec![],
            parent: Some("mid".to_owned()),
        })
        .unwrap();
        assert_eq!(reg.ancestors("leaf"), vec!["root", "mid", "leaf"]);
        assert_eq!(reg.ancestors("mid"), vec!["root", "mid"]);
        assert_eq!(reg.ancestors("root"), vec!["root"]);
    }

    // ── detect_scope ────────────────────────────────────────────────────

    #[test]
    fn detect_scope_explicit_tag_creates_def() {
        let mut reg = ScopeRegistry::default();
        let tags: Vec<String> = vec![
            "scope:finance".to_owned(),
            "year:2026".to_owned(),
            "type:invoice".to_owned(),
        ];
        let res = detect_scope(&tags, &mut reg);
        assert_eq!(res.scope, "finance");
        assert!(res.created);
        let def = reg.get("finance").unwrap();
        assert_eq!(def.order, vec!["type".to_owned(), "year".to_owned()]);
        assert_eq!(res.main_path, "/finance/invoice/2026");
        assert_eq!(res.chain, vec!["finance"]);
    }

    #[test]
    fn detect_scope_explicit_tag_existing_def() {
        let mut reg = ScopeRegistry::default();
        reg.upsert(ScopeDef {
            name: "finance".to_owned(),
            order: vec!["type".to_owned(), "year".to_owned()],
            parent: None,
        })
        .unwrap();
        let tags: Vec<String> = vec![
            "scope:finance".to_owned(),
            "year:2026".to_owned(),
            "type:invoice".to_owned(),
        ];
        let res = detect_scope(&tags, &mut reg);
        assert_eq!(res.scope, "finance");
        assert!(!res.created);
        assert_eq!(res.chain, vec!["finance"]);
    }

    #[test]
    fn detect_scope_full_coverage_match() {
        let mut reg = ScopeRegistry::default();
        reg.upsert(ScopeDef {
            name: "finance".to_owned(),
            order: vec!["type".to_owned(), "year".to_owned()],
            parent: None,
        })
        .unwrap();
        reg.upsert(ScopeDef {
            name: "records".to_owned(),
            order: vec!["type".to_owned(), "year".to_owned(), "dept".to_owned()],
            parent: None,
        })
        .unwrap();
        let tags: Vec<String> = vec!["year:2026".to_owned(), "type:invoice".to_owned()];
        let res = detect_scope(&tags, &mut reg);
        assert_eq!(res.scope, "finance");
        assert!(!res.created);
    }

    #[test]
    fn detect_scope_shortest_order_wins() {
        let mut reg = ScopeRegistry::default();
        reg.upsert(ScopeDef {
            name: "wide".to_owned(),
            order: vec!["a".to_owned(), "b".to_owned(), "c".to_owned()],
            parent: None,
        })
        .unwrap();
        reg.upsert(ScopeDef {
            name: "narrow".to_owned(),
            order: vec!["a".to_owned(), "b".to_owned()],
            parent: None,
        })
        .unwrap();
        let tags: Vec<String> = vec!["a:1".to_owned(), "b:2".to_owned()];
        let res = detect_scope(&tags, &mut reg);
        assert_eq!(res.scope, "narrow");
    }

    #[test]
    fn detect_scope_no_match_creates_auto() {
        let mut reg = ScopeRegistry::default();
        let tags: Vec<String> = vec!["year:2026".to_owned(), "type:invoice".to_owned()];
        let res = detect_scope(&tags, &mut reg);
        assert_eq!(res.scope, "auto-1");
        assert!(res.created);
        let def = reg.get("auto-1").unwrap();
        assert_eq!(def.order, vec!["type".to_owned(), "year".to_owned()]);
        assert_eq!(res.chain, vec!["auto-1"]);
    }

    #[test]
    fn detect_scope_auto_increments() {
        let mut reg = ScopeRegistry::default();
        reg.upsert(ScopeDef {
            name: "auto-1".to_owned(),
            order: vec![],
            parent: None,
        })
        .unwrap();
        let tags: Vec<String> = vec!["x:1".to_owned()];
        let res = detect_scope(&tags, &mut reg);
        assert_eq!(res.scope, "auto-2");
    }

    #[test]
    fn detect_scope_explicit_scope_key_ignored_in_doc_keys() {
        let mut reg = ScopeRegistry::default();
        let tags: Vec<String> = vec!["scope:finance".to_owned(), "x:1".to_owned()];
        let res = detect_scope(&tags, &mut reg);
        assert_eq!(res.scope, "finance");
        assert!(res.created);
        let def = reg.get("finance").unwrap();
        assert_eq!(def.order, vec!["x".to_owned()]);
    }

    #[test]
    fn detect_scope_with_parent_returns_full_chain() {
        let mut reg = ScopeRegistry::default();
        reg.upsert(ScopeDef {
            name: "teaching".to_owned(),
            order: vec![],
            parent: None,
        })
        .unwrap();
        reg.upsert(ScopeDef {
            name: "diploma".to_owned(),
            order: vec!["year".to_owned()],
            parent: Some("teaching".to_owned()),
        })
        .unwrap();
        let tags: Vec<String> = vec!["scope:diploma".to_owned(), "year:2025".to_owned()];
        let res = detect_scope(&tags, &mut reg);
        assert_eq!(res.scope, "diploma");
        assert_eq!(res.chain, vec!["teaching", "diploma"]);
    }

    // ── main_path_for ───────────────────────────────────────────────────

    #[test]
    fn main_path_full_order() {
        let tags: Vec<String> = vec![
            "type:invoice".to_owned(),
            "year:2026".to_owned(),
            "scope:finance".to_owned(),
        ];
        let path = main_path_for(
            &["finance".to_owned()],
            &["type".to_owned(), "year".to_owned()],
            &tags,
        );
        assert_eq!(path, "/finance/invoice/2026");
    }

    #[test]
    fn main_path_chain_aware() {
        let tags: Vec<String> = vec![
            "study-year:2025-2026".to_owned(),
            "student:Andrey".to_owned(),
            "doctype:article".to_owned(),
        ];
        let chain: Vec<String> = vec!["teaching".to_owned(), "diploma".to_owned()];
        let order: Vec<String> = vec![
            "study-year".to_owned(),
            "student".to_owned(),
            "doctype".to_owned(),
        ];
        let path = main_path_for(&chain, &order, &tags);
        assert_eq!(path, "/teaching/diploma/2025-2026/Andrey/article");
    }

    #[test]
    fn main_path_missing_middle_key() {
        let tags: Vec<String> = vec!["a:1".to_owned(), "c:3".to_owned()];
        let path = main_path_for(
            &["scope".to_owned()],
            &["a".to_owned(), "b".to_owned(), "c".to_owned()],
            &tags,
        );
        assert_eq!(path, "/scope/1/3");
    }

    #[test]
    fn main_path_sanitization() {
        let tags: Vec<String> = vec!["name:hello/world! yes".to_owned()];
        let path = main_path_for(&["scope".to_owned()], &["name".to_owned()], &tags);
        assert_eq!(path, "/scope/hello_world_ yes");
    }

    #[test]
    fn main_path_collapse_repeated_underscores() {
        let tags: Vec<String> = vec!["name:a//b!!c".to_owned()];
        let path = main_path_for(&["scope".to_owned()], &["name".to_owned()], &tags);
        assert_eq!(path, "/scope/a_b_c");
    }

    #[test]
    fn main_path_truncation() {
        let long_val = "a".repeat(80);
        let tags: Vec<String> = vec![format!("k:{long_val}")];
        let path = main_path_for(&["scope".to_owned()], &["k".to_owned()], &tags);
        let segs: Vec<&str> = path.trim_start_matches('/').split('/').collect();
        assert_eq!(segs[0], "scope");
        assert_eq!(segs[1].len(), 60);
    }

    #[test]
    fn main_path_no_values() {
        let tags: Vec<String> = vec!["plain".to_owned()];
        let path = main_path_for(
            &["finance".to_owned()],
            &["type".to_owned(), "year".to_owned()],
            &tags,
        );
        assert_eq!(path, "/finance");
    }

    #[test]
    fn main_path_chain_sanitized() {
        let tags: Vec<String> = vec!["a:1".to_owned()];
        let chain: Vec<String> = vec!["my scope".to_owned(), "sub-name".to_owned()];
        let path = main_path_for(&chain, &["a".to_owned()], &tags);
        assert_eq!(path, "/my scope/sub-name/1");
    }

    // ── process_document end-to-end ─────────────────────────────────────

    #[test]
    fn process_document_e2e() {
        let root = temp_root("pd-e2e");
        let repo = open_repository(root.display().to_string()).unwrap();

        seed_doc(
            &repo,
            "doc-1",
            vec![
                "student:Alice".to_owned(),
                "subject:Math".to_owned(),
                "year:2026".to_owned(),
            ],
            HashMap::new(),
        );

        let res = crate::props::process_document(&repo, "doc-1").unwrap();
        assert_eq!(res.scope, "auto-1");
        assert!(res.created);

        let doc = repo.get("doc-1".to_owned()).unwrap();
        assert!(
            doc.tags.contains(&"scope:auto-1".to_owned()),
            "scope tag should be added, got {:?}",
            doc.tags
        );
        assert_eq!(doc.extra.get("main_path").unwrap(), &res.main_path);
        assert_eq!(res.main_path, "/auto-1/Alice/Math/2026");

        let paths = repo.paths_of("doc-1".to_owned()).unwrap();
        assert!(
            paths.iter().any(|p| p.path == res.main_path),
            "assigned path should appear in paths_of, got {:?}",
            paths
        );

        // Idempotent second call: scope already known, created=false, same path
        let res2 = crate::props::process_document(&repo, "doc-1").unwrap();
        assert_eq!(res2.scope, res.scope);
        assert_eq!(res2.main_path, res.main_path);
        assert!(!res2.created, "second call must not create a new scope");

        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn process_document_explicit_scope() {
        let root = temp_root("pd-explicit");
        let repo = open_repository(root.display().to_string()).unwrap();

        let mut reg = ScopeRegistry::load(repo.root_dir());
        reg.upsert(ScopeDef {
            name: "finance".to_owned(),
            order: vec!["type".to_owned(), "year".to_owned()],
            parent: None,
        })
        .unwrap();
        reg.save(repo.root_dir()).unwrap();

        seed_doc(
            &repo,
            "doc-2",
            vec![
                "scope:finance".to_owned(),
                "type:invoice".to_owned(),
                "year:2026".to_owned(),
            ],
            HashMap::new(),
        );

        let res = crate::props::process_document(&repo, "doc-2").unwrap();
        assert_eq!(res.scope, "finance");
        assert!(!res.created);
        assert_eq!(res.main_path, "/finance/invoice/2026");

        let doc = repo.get("doc-2".to_owned()).unwrap();
        assert!(doc.tags.contains(&"scope:finance".to_owned()));
        assert_eq!(doc.extra.get("main_path").unwrap(), "/finance/invoice/2026");

        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn process_document_ancestor_tags_added() {
        let root = temp_root("pd-ancestor");
        let repo = open_repository(root.display().to_string()).unwrap();

        let mut reg = ScopeRegistry::load(repo.root_dir());
        reg.upsert(ScopeDef {
            name: "teaching".to_owned(),
            order: vec![],
            parent: None,
        })
        .unwrap();
        reg.upsert(ScopeDef {
            name: "diploma".to_owned(),
            order: vec!["year".to_owned()],
            parent: Some("teaching".to_owned()),
        })
        .unwrap();
        reg.save(repo.root_dir()).unwrap();

        seed_doc(
            &repo,
            "doc-3",
            vec!["scope:diploma".to_owned(), "year:2025".to_owned()],
            HashMap::new(),
        );

        let res = crate::props::process_document(&repo, "doc-3").unwrap();
        assert_eq!(res.scope, "diploma");
        assert_eq!(res.chain, vec!["teaching", "diploma"]);

        let doc = repo.get("doc-3".to_owned()).unwrap();
        // Both ancestor and most-specific scope tags present
        assert!(doc.tags.contains(&"scope:teaching".to_owned()));
        assert!(doc.tags.contains(&"scope:diploma".to_owned()));
        // Path is chain-aware: /teaching/diploma/2025
        assert_eq!(res.main_path, "/teaching/diploma/2025");
        assert_eq!(doc.extra.get("main_path").unwrap(), &res.main_path);

        let paths = repo.paths_of("doc-3".to_owned()).unwrap();
        assert!(paths.iter().any(|p| p.path == res.main_path));

        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn process_document_multi_chain_primary_wins() {
        let root = temp_root("pd-multi");
        let repo = open_repository(root.display().to_string()).unwrap();

        let mut reg = ScopeRegistry::load(repo.root_dir());
        reg.upsert(ScopeDef {
            name: "work".to_owned(),
            order: vec!["type".to_owned()],
            parent: None,
        })
        .unwrap();
        reg.upsert(ScopeDef {
            name: "project-x".to_owned(),
            order: vec!["year".to_owned()],
            parent: None,
        })
        .unwrap();
        reg.save(repo.root_dir()).unwrap();

        // Doc belongs to two unrelated scope chains — explicit scope:work,
        // and also carries scope:project-x (both full coverage)
        seed_doc(
            &repo,
            "doc-4",
            vec![
                "scope:work".to_owned(),
                "scope:project-x".to_owned(),
                "type:invoice".to_owned(),
                "year:2026".to_owned(),
            ],
            HashMap::new(),
        );

        let res = crate::props::process_document(&repo, "doc-4").unwrap();
        // Primary = most specific (both have 1-key order, tie-break alphabetical)
        assert_eq!(res.scope, "project-x");
        assert_eq!(res.chain, vec!["project-x"]);
        assert_eq!(res.main_path, "/project-x/2026");

        let doc = repo.get("doc-4".to_owned()).unwrap();
        // Both scope tags present
        assert!(doc.tags.contains(&"scope:work".to_owned()));
        assert!(doc.tags.contains(&"scope:project-x".to_owned()));
        // Only primary chain's main_path is stamped
        assert_eq!(doc.extra.get("main_path").unwrap(), "/project-x/2026");

        let _ = fs::remove_dir_all(&root);
    }

    /// Wiring guard: after the bulk/single reorganize pass applies a plan, the
    /// property/scope pass must have stamped `main_path` and assigned the path.
    #[test]
    fn reorganize_one_wires_main_path_assignment() {
        let root = temp_root("reorg-wiring");
        let repo = open_repository(root.display().to_string()).unwrap();

        {
            let mut store = repo.store().unwrap();
            store
                .put(
                    Document {
                        id: "sib".to_owned(),
                        parent_id: None,
                        kind: NodeKind::Document,
                        title: "Q3 Report".to_owned(),
                        mime_type: "text/plain".to_owned(),
                        size_bytes: 0,
                        checksum_sha256: String::new(),
                        tags: vec!["report".to_owned(), "quarterly".to_owned()],
                        created_at_ms: 1,
                        updated_at_ms: 1,
                        extra: HashMap::new(),
                    },
                    b"quarterly report for the finance team",
                )
                .unwrap();
            store
                .put_content(&Content {
                    document_id: "sib".to_owned(),
                    text: "quarterly report for the finance team".to_owned(),
                    source: "test".to_owned(),
                })
                .unwrap();
        }

        seed_doc(
            &repo,
            "doc-a",
            vec!["student:Alice".to_owned(), "subject:Math".to_owned()],
            HashMap::new(),
        );

        crate::api::auto_org::auto_org_reorganize_one(
            &repo,
            "doc-a".to_owned(),
            Default::default(),
        )
        .expect("reorganize_one must succeed");

        let doc = repo.get("doc-a".to_owned()).unwrap();
        let paths = repo.paths_of("doc-a".to_owned()).unwrap();

        assert!(
            doc.extra
                .get("main_path")
                .map(|p| paths.iter().any(|hp| hp.path == *p))
                .unwrap_or(false),
            "main_path must be stamped AND present in paths_of after reorganize, \
             extra={:?}, paths={:?}",
            doc.extra,
            paths.iter().map(|p| &p.path).collect::<Vec<_>>()
        );

        let _ = fs::remove_dir_all(&root);
    }
}
