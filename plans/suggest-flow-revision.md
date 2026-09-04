# Plan revision: no manual/AI distinction, old-name among choices, outcome feedback

## User decisions (supersede the earlier "keep auto-apply for non-manual" model)

1. **No manual-vs-AI gating.** Suggestions always auto-apply when the user clicks
   "Suggest *". The `title_manual` / `tags_manual` extra flags are no longer
   consulted to *gate* anything (they stay in the data for sync compatibility
   and as a UI hint only).
2. **ML learns manual edits with high weight.** When the user edits a title or
   tags themselves, the terms they typed are recorded as `accepted` feedback
   with weight **2.0** (vs 1.0 for choosing a suggestion chip), so the
   preference model strongly favors user-authored vocabulary.
3. **Old naming is always among the choices.** The flow: click "Suggest title"
   → the title changes to the top suggestion → the review card shows the other
   candidates **including the pre-suggestion (old) title** → user picks the
   best (or Keep) → the suggestion list disappears and feedback is recorded
   (accept for the chosen, reject for the unchosen alternatives' terms).

## Root causes being fixed (from the user's bug report)

- Dart `suggestTitle`/`suggestTags` used the suggestion-only `auto_org_organize`
  bridge and applied values via `repo.updateTitle`/`setTags`, which stamps the
  manual flags → first click poisons the doc, later clicks hit the (now
  invisible) skip branch → "spinner then silence", no alternatives ever stored.
- Alternatives were never persisted by these paths → review card never appeared.
- No outcome reporting: "already matches the suggestion", "no suggestion", etc.

## Implementation steps

### Core ([`core/src/api/auto_org.rs`](core/src/api/auto_org.rs), [`storage.rs`](core/src/api/storage.rs))

1. `apply_plan`: drop `title_manual`/`tags_manual` gating — always apply top
   suggestion (when different from current) and always store alternatives.
2. `store_plan_suggestions(plan, pre_title, pre_tags, source)`: rank-0 row =
   current value (`applied`); rank ≥ 1 = alternatives (`pending`), where the
   alternative list **starts with the pre-suggestion old title/tags** when they
   differ from the new top. Per-kind replace (dismiss stale pending rows first).
3. New `#[frb]` bridge fns (replacing the Dart-side manual apply):
   - `auto_org_suggest_title(repo, document_id, config) -> SuggestOutcome`
   - `auto_org_suggest_tags(repo, document_id, config) -> SuggestOutcome`
   - `SuggestOutcome { status: Applied | AlreadyCurrent | NoSuggestion,
     stored_pending: usize }` — applies the top suggestion **directly via
     `repo.put`-style internal write** (no manual-flag stamping), then stores
     alternatives including the old name.
4. `confirm_current(kind)`: keeps current value, stamps the manual flag
   (endorsement), records accept (weight 1.0) for kept terms + reject for
   alternative-only terms; dismisses pending of that kind.
5. `apply_suggestion`: unchanged semantics (apply chosen, dismiss others) but
   feedback weight depends on the suggestion `source` (`user` → 2.0).
6. `repo.update_title` / `repo.set_tags` (user-edit paths): record accept
   feedback for the new terms (weight 2.0) — behind `LearningMode` off-guard
   (record only when `suggestion_learning_mode` is Basic; simplest: always
   record, model neutral when Off re-ranking disabled, and rows are tiny).
   Confirm with user intent: recording is unconditional on-device.

### Dart ([`app/lib/src/features/document_service.dart`](app/lib/src/features/document_service.dart))

7. `suggestTitle`/`suggestTags` call the new bridge fns and return
   `SuggestResult { plan, outcome }`; delete the Dart-side manual-apply logic.
   Fakes mirror the same semantics (alternatives stored, old name included,
   outcome kinds) without touching flags for suggestion applies.

### UI ([`app/lib/src/ui/document_view.dart`](app/lib/src/ui/document_view.dart))

8. Outcome snackbars:
   - `Applied` → "Title suggested: {t}" / "Tags suggested: …"
   - `AlreadyCurrent` → "Title already matches the suggestion"
   - `NoSuggestion` → "No title suggestion available"
   - After any suggest with `stored_pending > 0` the review card shows with the
     old-name chip among alternatives; collapses after a choice.
9. The current-value label in the review row comes from the live document.

### Tests

10. Rust: old-title alternative present after suggest; suggest applies on a
    previously-manual doc; outcome kinds; weight 2.0 on manual edit; confirm
    dismisses + records; handle-reuse regressions still green.
11. Flutter: old-title chip visible after suggest; snackbar per outcome;
    manual doc still gets suggestions applied; existing manual-flag tests
    updated to the new no-gating contract.

### Verification

12. `cargo fmt && cargo clippy --all-targets -- -D warnings && cargo test`;
    `just codegen`; `fvm flutter analyze && fvm flutter test`; commit.
