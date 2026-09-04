# Title Suggestion Tuning — Research + Implementation Plan

**Project:** `docer` (Flutter `app/` + Rust core `core/`, glued by flutter_rust_bridge)
**Scope:** Rust-core-only tuning of **title suggestion generation** (deterministic classic-ML pipeline in `core/src/auto_org/organizer.rs`). No FRB codegen. No `core/src/api/**` signature changes. No `OrgConfig` field changes.
**Status:** Research + plan only. No source changes made.
**Verified as of:** 2026-09-04 (session context `zoo-context.md` facts confirmed against source).

---

## 1. Goals

The user wants title suggestions to:

1. **(a) Join words with SPACES** — not `-` or `_` — when building *title* candidates.
2. **(b) Depend more on document CONTENT than the initial file name**, especially when the filename's script/language differs from the content script (content keywords should dominate). **Constraint (supersedes earlier notes): filename tokens are NEVER dropped/excluded** from title candidates — their **weight** is reduced instead. When the filename script mismatches the content script, filename tokens get a strong (extra-low) down-weight; otherwise a "content-dominant blend".
3. Content-derived tokens must **always outrank** filename-derived tokens when both exist.

This is about **suggestion generation** (deterministic determinism), NOT preference prediction (learning re-rank is orthogonal and left intact).

---

## 2. Verified Anchor Points (file:line)

### 2.1 `core/src/auto_org/rules.rs`
- [`RuleSet`](core/src/auto_org/rules.rs:34) holds `filename_template` (default `"{keywords}-{date}"` via [`RuleSet::default_template()`](core/src/auto_org/rules.rs:42)).
- [`render_filename()`](core/src/auto_org/rules.rs:81) — **filename rendering.**
  - `let keywords = join_top(&signals.keywords, 3, "-");` (line 82) — joins **top-3** keywords with `-`.
  - `tags` joined with `-` (line 83).
  - `join_top()` (line 98) — `items.iter().take(n).join(sep)`.
  - Replaces `{keywords}`, `{tags}`, `{title}`, `{date}`, `{ext}` (lines 85–90).
- **Test note:** `render_filename_substitutes_placeholders` (line 174) asserts `"{keywords}-{date}.{ext}"` → `"invoice-acme-2026-2026-09-01.pdf"` (line 177). This is a **filename** test and must keep passing unchanged.

### 2.2 `core/src/auto_org/keywords.rs`
- [`extract_keywords()`](core/src/auto_org/keywords.rs:19) — TF-IDF (or TF fallback) over `text`, returns top-k `<String>`.
- [`weighted_terms()`](core/src/auto_org/keywords.rs:51) — calls `model.vectorize(text)` → `HashMap<term, f64 weight>`.
- [`rule_fallback_keywords()`](core/src/auto_org/keywords.rs:59) — fallback from `doc.title` (the metadata title / initial file base-name stem) when body is sparse. **Only called in tests today** (verified: no production call sites).
- [`sanitize_filename()`](core/src/auto_org/keywords.rs:67) — joins words with `_` and strips `/ \ : * ? " < > | \n \r \t`; caps at 120 chars.
- **Key finding — FILENAME TOKENS ARE NOT SEPARATELY MIXED WITH CONTENT TOKENS TODAY.** `extract_keywords` runs on `doc.text` (content). The filename (a document's `title`/base-name) only enters via (i) `DocSignals.title` placeholder in the template, and (ii) the `alt_titles` "cleaned original title" variant. There is **no weighted merge (list of `(term, weight)`)** — `extract_keywords` returns already-truncated `String`s, so weights are not currently propagated to title construction.

### 2.3 `core/src/auto_org/organizer.rs`
- [`MAX_TITLE_ALTS`](core/src/auto_org/organizer.rs:38) = 5.
- [`organize_with_model()`](core/src/auto_org/organizer.rs:154):
  - `let kw = keywords::extract_keywords(&doc.text, Some(&model), None, keywords::DEFAULT_TOP_K);` (line 221).
  - `let signals = DocSignals { tags, keywords: kw, title: doc.title.clone(), extension, date: "" };` (lines 223–229).
  - `let template = &self.config.rules.filename_template;` (line 230).
  - [`suggested_title = sanitize_filename(&rules::render_filename(template, &signals));`](core/src/auto_org/organizer.rs:231) — **THE single shared render path**: `suggested_title` (rank-0) is literally the *filename template* rendered + sanitized. The same string conceptually feeds both "title" and "filename" today. This is the pivot for design requirement (a).
  - `alt_titles = self.alt_titles(doc, &model, &suggested_title, prefs, is_learning);` (line 234).
- [`alt_titles()`](core/src/auto_org/organizer.rs:283): builds `"{kw0}-{kw1}"`, `"{kw0}-{kw1}-{kw2}"`, `kw0` raw, and `sanitize_filename(doc.title.trim())` (line 304) — the **cleaned original title/filename** as a fallback alternative. All joined with `-`.
- `OrgPlan { suggested_title: Some(suggested_title), alt_titles, ... }` (lines 265–275).
- **Note:** `deterministic_organizer` never puts `date` into signals (line 228: `date: String::new()`), so the default `"{keywords}-{date}"` renders with an empty date → title is effectively `kw0-kw1-kw2` (then `sanitize_filename`, which uses `_`).

### 2.4 `core/src/api/auto_org.rs`
- [`auto_org_suggest_title()`](core/src/api/auto_org.rs:741): builds plan via `organize_with_model`, then trims:
  ```rust
  let trimmed = title.trim().trim_end_matches(['-', '_', '.', ' ']).to_owned();
  ```
  (lines 758–761). Only trims **trailing** separators; internal `-`/`_` remain. Confirmed.
- [`organize_document()`](core/src/api/auto_org.rs:310) — same trailing-trim logic (lines 335–338); used by the ingestion pipeline.
- [`store_plan_suggestions()`](core/src/api/auto_org.rs:162) — persists `plan.suggested_title` (line 224–229) then `plan.alt_titles` (line 238) as `SuggestionKind::Title` rows with `payload = title string`. Rank 0 = applied; rank ≥ 1 pending. Also stores pre-title as the first alternative (lines 230–236).
- [`payload_terms()`](core/src/api/auto_org.rs:966) — Title payload is the whole trimmed string as a single term (`vec![s.payload.trim()]`) — **unchanged**; title string shape flows through verbatim.
- [`auto_org_default_rules()`](core/src/api/auto_org.rs:991) — builds `RuleSet{ filename_template: RuleSet::default_template() }` (`"{keywords}-{date}"`).
- Other FRB APIs (`auto_org_organize`, reorganize* , suggest_tags, apply/confirm/dismiss, resolve, reset, default_config) routed through the same `OrgPlan` — **no signature impact** from this change.

### 2.5 `core/src/auto_org/text.rs`
- [`Tokenizer::tokenize()`](core/src/auto_org/text.rs:17) — lowercases **ASCII**, splits on non-alphanumeric, drops stopwords and 1-char tokens.
- [`term_frequencies()`](core/src/auto_org/text.rs:56); [`TfIdfModel::fit/vectorize/cosine`](core/src/auto_org/text.rs:73).
- **No script-detection helper exists.** Proposed home for a new helper (see §3.4). `text` is already the natural util module (no AI dep).

### 2.6 `core/src/auto_org/generative.rs`
- [`generate_filename()`](core/src/auto_org/generative.rs:17) also routes through `sanitize_filename` (line 44) and `apply_generated` sets `plan.suggested_title` (line 50). **Generative path is out of scope** (deterministic pipeline only). `sanitize_filename` keeps `_` joins — fine for filename; note that the generative tier also yields a "title" that uses `_`, but that is the LLM tier, not this task.

### 2.7 Dart side (no changes needed)
- [`_orgConfig()`](app/lib/src/features/document_service.dart:433) constructs `OrgConfig` exhaustively (enabled, generativeEnabled, dedupThreshold, shingleK, clusterK, rules, learningMode). Confirmed **no new OrgConfig field is introduced**, so this stays exhaustive and **no FRB codegen / no Dart change is required**. (If a config field were ever added, `orgConfig`/`OrgConfig` construction would need to remain exhaustive — flagged, not needed.)

---

## 3. Findings Summary (what each requirement means here)

| Requirement | Reality today | Gap |
|---|---|---|
| (a) spaces not `-`/`_` in titles | `suggested_title` and `alt_titles` are built from the **filename template** (`render_filename`, joins with `-`) then `sanitize_filename` (joins with `_`). | Title path and filename path are **the same render**. Must split them. |
| (b) content-over-filename by weighting | Filename tokens are **not explicitly merged** with content tokens; the filename only enters as a template placeholder / cleaned-original alternative. No weight blending exists. | Need a weighted merge of content tokens + (reduced-weight) filename tokens for **title** candidates. |
| (b) script mismatch down-weight | No script detection exists. | Add `detect_script` in `text.rs`. |

Because the current default template is `{keywords}-{date}` with empty `date`, the filename template today contributes **no filename tokens at all** in the default config — the title is purely content-keyword based. The filename-weighting work is therefore most relevant when (i) the content is sparse/empty (content yields no tokens) or (ii) we explicitly fold filename tokens into title candidates. The plan below adds filename tokens **with reduced weight** into a blended **weighted** title-keyword list, satisfying the user constraint (never drop filename tokens).

---

## 4. Design

### 4.1 Split title rendering from filename rendering (requirement a)

Today `suggested_title = sanitize_filename(render_filename(template, signals))` ([organizer.rs:231](core/src/auto_org/organizer.rs:231)).

**Proposed change (in `core/src/auto_org/organizer.rs`, minimal, local):**

- Keep [`rules::render_filename()`](core/src/auto_org/rules.rs:81) **unchanged** — it remains the **filename/path+sanitized** renderer and still uses `-`/`_`. This preserves all existing filename-template behavior and its tests ([`render_filename_substitutes_placeholders`](core/src/auto_org/rules.rs:174)).
- Add a **new title renderer** that joins the top title keywords with **spaces**:

```rust
// organizer.rs — new private helper (Rust pseudocode)
fn render_title(keywords: &[String], max: usize) -> String {
    let joined = keywords.iter().take(max).cloned().collect::<Vec<_>>().join(" ");
    if joined.trim().is_empty() { "document".to_owned() } else { joined }
}
```

- In `organize_with_model` (line 230–231), split the assignment:
  ```rust
  let signals = DocSignals { keywords: title_keywords, /* ... */ };
  // FILENAME path (unchanged semantics, still sanitized):
  let filename = sanitize_filename(&rules::render_filename(template, &signals));
  // TITLE path (spaces, no sanitize that would turn spaces into '_'):
  let suggested_title = render_title(&title_keywords, 3);
  ```
  Keep both in the plan; the caller already treats `suggested_title` as the displayed/applied **title** (the on-disk file is never renamed — confirmed in [`organize_document`](core/src/api/auto_org.rs:300-302)). The template/filename render is retained so any **actual** filename use keeps `-`/`_`.

- **Alternative titles** in [`alt_titles()`](core/src/auto_org/organizer.rs:283): change the joins from `"-"` to `" "` for the keyword variants, and replace `sanitize_filename(doc.title.trim())` (line 304) with a space-joined cleaned title:
  ```rust
  fn clean_title_words(s: &str) -> String {
      s.split_whitespace().collect::<Vec<_>>().join(" ")  // no '_'
  }
  ```
  (Keep dedup + `MAX_TITLE_ALTS` cap unchanged.)

### 4.2 Content-over-filename via weighting (requirement b) — never exclusion

Introduce a **weighted keyword list** for title construction. Filename tokens stay in the pool, just with a reduced weight, and content tokens dominate.

```rust
// keywords.rs — new weighted extraction helper (Rust pseudocode)
pub const CONTENT_WEIGHT: f64 = 1.0;
pub const FILENAME_WEIGHT: f64 = 0.25;                 // normal blend (content-dominant)
pub const FILENAME_SCRIPT_MISMATCH_WEIGHT: f64 = 0.01; // strong penalty, still > 0

/// Weighted `(term, weight)` pool for TITLE candidates.
pub fn weighted_title_terms(
    content_text: &str,
    model: Option<&TfIdfModel>,
    filename: &str,               // initial file name / doc.title
    top_k: usize,
) -> Vec<(String, f64)> {
    let mut out: HashMap<String, f64> = HashMap::new();
    // Content: TF-IDF for the body.
    for (term, w) in weighted_terms_or_tf(content_text, model) {
        *out.entry(term).or_insert(0.0) += w * CONTENT_WEIGHT;
    }
    // Filename: never dropped, only down-weighted.
    let fw = if text::scripts_mismatch(filename, content_text) {
        FILENAME_SCRIPT_MISMATCH_WEIGHT
    } else {
        FILENAME_WEIGHT
    };
    for (term, w) in term_frequencies(filename) {     // reuse existing tf
        *out.entry(term).or_insert(0.0) += w * fw;
    }
    // Deterministic order: weight desc, then term asc (matches extract_keywords).
    let mut scored: Vec<(String, f64)> = out.into_iter().collect();
    scored.sort_by(|a, b| b.1.total_cmp(&a.1).then_with(|| a.0.cmp(&b.0)));
    scored.truncate(top_k);
    scored
}
```

Key invariant: a content term's minimum weight is `>= CONTENT_WEIGHT` per occurrence while a filename term is `<= 0.25` (or `0.01`) per occurrence — so as long as **any** content term exists, it outranks every filename term. Filename terms only surface when content yields nothing (empty text), satisfying "content always outranks filename when both exist" and "filename tokens only surface when content yields nothing."

**Where the filename comes from:** the document's `title`/base-name (`doc.title`, the `CorpusDoc.title` field; in the DA layer this is the file base-name after ingest). `CorpusDoc` already carries `title` ([organizer.rs:43-50](core/src/auto_org/organizer.rs:43)).

**Wiring in organizer.rs:**
- Replace the title-keyword source at [line 221/223](core/src/auto_org/organizer.rs:221) with:
  ```rust
  let title_terms = keywords::weighted_title_terms(&doc.text, Some(&model), &doc.title, 5);
  let title_keywords: Vec<String> = title_terms.iter().map(|(t, _)| t).cloned().collect();
  ```
  Feed `title_keywords` into `DocSignals` (for the filename render path) and into `render_title` / `alt_titles`.
- Keep `suggested_path`/tagging on the **content-only** TF-IDF keywords (unchanged), since placement shouldn't change.

**Scope of `-`/`_` trimming at [api lines 758-761 / 335-338]:** these trim only *trailing* separators; with spaces-only titles the internal separators disappear naturally, so **no change needed there**. The trailing-trim remains a harmless safety net.

### 4.3 Script detection helper (new, small) — `core/src/auto_org/text.rs`

Add a tiny Unicode-range-based detector (no external deps):

```rust
// text.rs — enum + detector
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Script { Cyrillic, Latin, Other }

pub fn detect_script(sample: &str) -> Script {
    let mut cyr = 0usize; let mut lat = 0usize;
    for c in sample.chars() {
        match c {
            '\u{0400}'..='\u{04FF}' => cyr += 1,   // Cyrillic block (+ extensions)
            'a'..='z' | 'A'..='Z' => lat += 1,
            _ => {}
        }
    }
    let total = cyr + lat;
    if total == 0 { return Script::Other; }
    if cyr * 2 >= total && (cyr as f64) > (lat as f64) { Script::Cyrillic }
    else if lat == 0 && cyr > 0 { Script::Cyrillic }
    else if cyr == 0 && lat > 0 { Script::Latin }
    else { Script::Other }
}

/// True when the primary scripts of filename and content differ.
pub fn scripts_mismatch(filename: &str, content: &str) -> bool {
    let a = detect_script(filename);
    let b = detect_script(content);
    a != Script::Other && b != Script::Other && a != b
}
```

Covers the requirement's example (Cyrillic filename + Latin content → mismatch → `FILENAME_SCRIPT_MISMATCH_WEIGHT`). `Other` is treated as "no signal" → no penalty. Placed in `text.rs` (the existing util module, no AI dependency). Only `scripts_mismatch` needs to be `pub` (used by `keywords.rs`).

### 4.4 Learning re-rank interaction

- The preference-model re-ranking at [organizer.rs:205-217 (tags) and alt_titles:309-311] is **orthogonal** and operates on *strings* (`prefs.rerank_titles`). It stays intact. Because filename terms end up ranked below content terms at generation time, learning cannot promote them above present content terms except by explicit user acceptance — acceptable and out of scope.

### 4.5 FRB codegen / OrgConfig

- **NO FRB codegen needed.** No `core/src/api/**` signature changes; no new `OrgConfig`/`RuleSet` fields; no new FRB-exposed functions. All changes are private helpers + one new pub helper in `core/src/auto_org/{organizer,keywords,text}.rs`.
- **NO Dart changes** ([`_orgConfig`](app/lib/src/features/document_service.dart:433) stays exhaustive).
- The user-visible `filenameTemplate` (default `"{keywords}-{date}"`) continues to control the **filename** render. Title rendering is decoupled (spaces) and is not template-driven — a deliberate, minimal deviation; flagging this explicitly so it is a conscious choice. If a user-configurable title separator were ever wanted, that would require a new `OrgConfig` field → FRB codegen (flagged, out of scope).

---

## 5. Minimal Diff Sketch (Rust pseudocode)

**`core/src/auto_org/text.rs`** — add `Script` enum, `detect_script`, `scripts_mismatch` (see §4.3).

**`core/src/auto_org/keywords.rs`** — add constants + `weighted_title_terms(content, model, filename, top_k)` (see §4.2). Reuse existing `term_frequencies`, `weighted_terms`.

**`core/src/auto_org/organizer.rs`**:
- Add `render_title(keywords, max) -> String` (spaces).
- In `organize_with_model` (~lines 220–235):
  ```rust
  let title_terms = keywords::weighted_title_terms(&doc.text, Some(&model), &doc.title, 5);
  let title_keywords: Vec<String> = title_terms.into_iter().map(|(t, _)| t).collect();
  // signals.keywords = title_keywords
  let filename = sanitize_filename(&rules::render_filename(template, &signals)); // unchanged
  let suggested_title = render_title(&title_keywords, 3);                        // NEW (spaces)
  ```
- In `alt_titles` (~lines 283–307): join keyword variants with `" "`; replace `sanitize_filename(doc.title.trim())` with a space-joined clean title. Keep dedup/cap and the `rank0` exclusion.

**`core/src/api/auto_org.rs`** — **no changes** (trailing-trim stays as harmless safety net).

**No changes** to `rules.rs`, `config.rs`, `generative.rs`, `core/src/api/**` signatures, or any Dart file.

---

## 6. Test Plan

### 6.1 New tests to add

- **`core/src/auto_org/text.rs`:**
  - `detect_script_cyrillic` — Cyrillic sample → `Script::Cyrillic`.
  - `detect_script_latin` — ASCII/Latin sample → `Script::Latin`.
  - `detect_script_other` — mixed/neither → `Script::Other`.
  - `scripts_mismatch_cyrillic_vs_latin` — Cyrillic filename + Latin content → `true`; same-script → `false`.

- **`core/src/auto_org/keywords.rs`:**
  - `weighted_title_terms_content_dominates` — content has any term → every content term ranked above every filename term.
  - `weighted_title_terms_filename_never_dropped` — with empty content, filename terms still present (non-empty), satisfying the never-exclude constraint.
  - `weighted_title_terms_script_mismatch_penalizes` — Cyrillic filename + Latin content: filename terms present but at the very bottom; Latin content terms at the top.

- **`core/src/auto_org/organizer.rs` (in `core/src/auto_org/tests.rs` or a new `#[cfg(test)]` module):**
  - `suggested_title_uses_spaces_only` — rank-0 `suggested_title` contains no `-` or `_` (spaces joined), given non-empty content.
  - `alt_titles_use_spaces_only` — all alternatives free of `-`/`_` (except punctuation-free words).
  - `cyrillic_filename_latin_content_title_from_content` — Cyrillic filename + Latin content → rank-0 title built from **content** tokens; `filename != rank0`; filename tokens (if any) never at rank 0 when content tokens exist; filename tokens may only appear at lower rank or absent.
  - Symmetric `latin_filename_cyrillic_content_title_from_content` — mirror case.
  - `filename_template_behavior_unchanged` — `rules::render_filename` still yields `-`-joined output (guard against regression), i.e. the existing render test keeps passing and a new assertion confirms filename path still joins with `-` while title joins with spaces.

### 6.2 Existing tests to UPDATE (assert `-`-separated titles)

- **`core/src/api/auto_org.rs:1330-1333`** — `same_repository_handle_survives_multiple_reorganize_one_calls` asserts `doc.title == "acme-invoice-quarterly"`. Must become `"acme invoice quarterly"` (spaces). **This is the one hard-coded hyphenated title assertion that will break.**

### 6.3 Existing tests that must KEEP PASSING (no change)

- `core/src/auto_org/rules.rs:174` `render_filename_substitutes_placeholders` — filename render keeps `-` (e.g. `"invoice-acme-2026-2026-09-01.pdf"`).
- `core/src/auto_org/tests.rs:99` `organize_reuses_tags_and_resolves_path` — asserts `suggested_title` ends with `.pdf`; the title/filename still ends with extension via the filename render/Signals. **Verify post-change**: since rank-0 `suggested_title` is now the *title* (spaces, no extension), this assertion may need to move to a filename-specific check (see §7 note).
- `core/src/auto_org/tests.rs:118-119` determinism (`a.suggested_title == b.suggested_title`) — remains true (still deterministic).
- `core/src/auto_org/tests.rs:216-219` generative filename `"acme_supplier_invoice"` — generative tier unchanged.
- `core/src/api/ingest.rs:301-316` `ingested_file_gets_auto_tags_and_content_derived_title` — asserts title is content-derived (`contains("invoice"|"quarterly"|...)`) and `!= "meeting_notes"`; should still pass because content now dominates even more. (Stem `meeting_notes` is `_`-joined; title becomes space-joined content terms.)
- `core/src/storage/tests.rs` — suggestion storage payload tests (`rows[0].payload == "Suggested title"`) — storage shape unchanged.
- `feedback.rs` re-rank tests (`"quarterly-report"`, `"a-t-b"`) — use opaque strings; unchanged.

### 6.4 Test runner scope

Tests live in `core/src/auto_org/{tests,organizer,keywords,text,rules}.rs` and inline in `core/src/api/auto_org.rs` + `core/src/api/ingest.rs`. Run via `cargo test --manifest-path core/Cargo.toml`.

---

## 7. Verification Commands (from [`justfile`](justfile:19))

Run from repo root (`/Users/andreymelnikov/programming/self/docer`); fish shell on macOS.

1. Format (with check to be CI-clean):
   ```
   just fmt-core
   just fmt-core-check
   ```
   (Equivalently: `cargo fmt --manifest-path core/Cargo.toml` / `cargo fmt --manifest-path core/Cargo.toml -- --check`.)

2. Lint (deny warnings):
   ```
   just lint-core
   ```
   (`cargo clippy --manifest-path core/Cargo.toml --all-targets -- -D warnings`)

3. Tests:
   ```
   just test-core
   ```
   (`cargo test --manifest-path core/Cargo.toml`)

4. Targeted title tests first:
   ```
   cargo test --manifest-path core/Cargo.toml auto_org
   cargo test --manifest-path core/Cargo.toml auto_org::keywords
   cargo test --manifest-path core/Cargo.toml auto_org::text::tests
   cargo test --manifest-path core/Cargo.toml api::auto_org::tests
   ```

**Do NOT run:** `just codegen`, `fvm flutter`/`fvm dart` (repo rule: `fvm` only for Dart/Flutter; not needed here).

**One behavioral note to verify during implementation:** with rank-0 `suggested_title` now space-joined and no extension, the existing [tests.rs:99](core/src/auto_org/tests.rs:99) assertion `suggested_title.endswith(".pdf")` will fail. Resolution: assert the extension on a filename-flavored value if any is retained, or relax to a title-content assertion (the on-disk filename is never renamed; the applied title is content text). Concrete decision belongs to the implementation pass; the plan favors keeping `render_filename` for any genuine filename use and asserting the title's word content + spaces.

---

## 8. FRB Codegen / OrgConfig — Explicit Statement

- **FRB codegen: NOT required.** No changes to `core/src/api/**` signatures; no new FRB-exposed functions; no changes to `core/src/frb_generated.rs` or `app/lib/src/rust/**`.
- **OrgConfig: NO new fields.** All behavior is internal (weight constants + helpers). Dart [`_orgConfig()`](app/lib/src/features/document_service.dart:433) remains exhaustive with no edits.
- Only condition that WOULD force codegen (flagged, excluded): adding a title-separator / filename-weight **config field** or changing any `core/src/api/**` signature.
