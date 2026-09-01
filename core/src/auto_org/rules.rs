//! User-editable placement rules and filename templates.
//!
//! Placement is deterministic: predicted tags/topics and extracted keywords are
//! mapped to hierarchy paths through ordered rules. Rules are plain data
//! (serde-serializable so the Dart layer can edit and persist them) and are
//! applied in order — the first matching rule wins. If no rule matches, an
//! optional fallback path is used.

use serde::{Deserialize, Serialize};

/// How a rule's `when` value is matched against document signals.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum MatchKind {
    Tag,
    Keyword,
    TitleContains,
}

/// A single placement rule: when `signals` match, place the document at `path`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PlacementRule {
    pub id: String,
    pub match_kind: MatchKind,
    pub value: String,
    pub path: String,
    pub priority: i32,
}

/// The rule set + fallbacks that govern deterministic placement and renaming.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RuleSet {
    pub placement: Vec<PlacementRule>,
    pub fallback_path: Option<String>,
    /// Supported placeholders: `{keywords}`, `{tags}`, `{title}`, `{date}`, `{ext}`.
    pub filename_template: String,
}

impl RuleSet {
    pub fn default_template() -> String {
        "{keywords}-{date}".to_owned()
    }
}

/// The document signals available to rules and templates.
#[derive(Debug, Clone, Default)]
pub struct DocSignals {
    pub tags: Vec<String>,
    pub keywords: Vec<String>,
    pub title: String,
    pub extension: String,
    pub date: String,
}

/// Resolve a path for `signals` using `rules`, returning the first matching rule
/// path, or the fallback.
pub fn resolve_path(rules: &RuleSet, signals: &DocSignals) -> Option<String> {
    let mut ordered = rules.placement.clone();
    ordered.sort_by_key(|r| r.priority);

    for rule in ordered {
        let matched = match rule.match_kind {
            MatchKind::Tag => signals.tags.iter().any(|t| t == &rule.value),
            MatchKind::Keyword => signals.keywords.iter().any(|k| k == &rule.value),
            MatchKind::TitleContains => signals
                .title
                .to_lowercase()
                .contains(&rule.value.to_lowercase()),
        };
        if matched {
            return Some(rule.path);
        }
    }

    rules.fallback_path.clone()
}

/// Render the filename template with the document signals.
pub fn render_filename(template: &str, signals: &DocSignals) -> String {
    let keywords = join_top(&signals.keywords, 3, "-");
    let tags = join_top(&signals.tags, 3, "-");

    let mut out = template
        .replace("{keywords}", &keywords)
        .replace("{tags}", &tags)
        .replace("{title}", &signals.title)
        .replace("{date}", &signals.date)
        .replace("{ext}", &signals.extension);

    if out.is_empty() {
        out = "document".to_owned();
    }
    out
}

fn join_top(items: &[String], n: usize, sep: &str) -> String {
    items.iter().take(n).cloned().collect::<Vec<_>>().join(sep)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn signals() -> DocSignals {
        DocSignals {
            tags: vec!["invoice".to_owned(), "receipt".to_owned()],
            keywords: vec!["invoice".to_owned(), "acme".to_owned(), "2026".to_owned()],
            title: "Acme Invoice Q1".to_owned(),
            extension: "pdf".to_owned(),
            date: "2026-09-01".to_owned(),
        }
    }

    #[test]
    fn resolve_path_first_matching_rule_wins() {
        let rules = RuleSet {
            placement: vec![
                PlacementRule {
                    id: "r1".to_owned(),
                    match_kind: MatchKind::Keyword,
                    value: "recipe".to_owned(),
                    path: "/recipes".to_owned(),
                    priority: 0,
                },
                PlacementRule {
                    id: "r2".to_owned(),
                    match_kind: MatchKind::Tag,
                    value: "invoice".to_owned(),
                    path: "/finance/invoices".to_owned(),
                    priority: 1,
                },
            ],
            fallback_path: Some("/inbox".to_owned()),
            filename_template: RuleSet::default_template(),
        };
        assert_eq!(
            resolve_path(&rules, &signals()),
            Some("/finance/invoices".to_owned())
        );
    }

    #[test]
    fn resolve_path_falls_back_when_no_match() {
        let rules = RuleSet {
            placement: vec![],
            fallback_path: Some("/inbox".to_owned()),
            filename_template: RuleSet::default_template(),
        };
        assert_eq!(resolve_path(&rules, &signals()), Some("/inbox".to_owned()));
    }

    #[test]
    fn title_contains_matches_case_insensitively() {
        let rules = RuleSet {
            placement: vec![PlacementRule {
                id: "r".to_owned(),
                match_kind: MatchKind::TitleContains,
                value: "invoice".to_owned(),
                path: "/finance".to_owned(),
                priority: 0,
            }],
            fallback_path: None,
            filename_template: RuleSet::default_template(),
        };
        assert_eq!(
            resolve_path(&rules, &signals()),
            Some("/finance".to_owned())
        );
    }

    #[test]
    fn render_filename_substitutes_placeholders() {
        assert_eq!(
            render_filename("{keywords}-{date}.{ext}", &signals()),
            "invoice-acme-2026-2026-09-01.pdf"
        );
        assert_eq!(render_filename("{tags}", &signals()), "invoice-receipt");
    }
}
