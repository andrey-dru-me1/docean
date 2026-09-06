/// Tag-completion, validation, and rename utilities for the hierarchical tag
/// system.  These are pure functions with no service/repository dependency so
/// they can be unit-tested in isolation.
library;

/// Suggest up to [limit] completions for [query] against [allTags].
///
/// Matching tiers (highest priority first, deduplicated — a tag appears once
/// in its highest tier):
///  1. **exact** — tag == query (case-insensitive).
///  2. **full-prefix** — tag startsWith query.
///  3. **any-segment-prefix** — any segment (split on `/`) startsWith query.
///  4. **subsequence** — after removing `/`, every char of query appears in
///     order inside the flattened tag (e.g. `smitml` matches
///     `study/mit/machine-learning` because `smitml` is a subsequence of
///     `studymitmachinelearning`).
///
/// Input order is preserved within each tier.  An empty or blank query
/// returns `const []`.
List<String> suggestTagCompletions(
  String query,
  Iterable<String> allTags, {
  int limit = 8,
}) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return const [];

  final seen = <String>{};
  final exact = <String>[];
  final fullPrefix = <String>[];
  final segPrefix = <String>[];
  final subseq = <String>[];

  final qFlat = q.replaceAll('/', '');

  for (final tag in allTags) {
    final key = tag.toLowerCase();
    if (!seen.add(key)) continue;

    // Tier 1 — exact
    if (key == q) {
      exact.add(tag);
      continue;
    }

    // Tier 2 — full prefix
    if (key.startsWith(q)) {
      fullPrefix.add(tag);
      continue;
    }

    // Tier 3 — any-segment prefix
    final segments = tag.split('/');
    if (segments.any((s) => s.toLowerCase().startsWith(q))) {
      segPrefix.add(tag);
      continue;
    }

    // Tier 4 — subsequence over flattened path (without `/`)
    if (_isSubsequence(qFlat, key.replaceAll('/', ''))) {
      subseq.add(tag);
    }
  }

  final results = [...exact, ...fullPrefix, ...segPrefix, ...subseq];
  if (results.length <= limit) return results;
  return results.sublist(0, limit);
}

/// Returns `true` when every character of [pattern] appears in [target] in
/// order (not necessarily contiguously).
bool _isSubsequence(String pattern, String target) {
  var pi = 0;
  for (var ti = 0; ti < target.length && pi < pattern.length; ti++) {
    if (target[ti] == pattern[pi]) pi++;
  }
  return pi == pattern.length;
}

/// Validate a tag path string.
///
/// Returns `null` when the path is valid, otherwise a human-readable error
/// message describing what is wrong.
String? validateTagPath(String tag) {
  final trimmed = tag.trim();
  if (trimmed.isEmpty) return 'Tag cannot be empty';
  if (trimmed.startsWith('/')) return 'Tag must not start with /';
  if (trimmed.endsWith('/')) return 'Tag must not end with /';
  if (trimmed.contains('//')) return 'Tag must not contain empty segments';

  final segments = trimmed.split('/');
  for (final seg in segments) {
    if (seg.trim().isEmpty) return 'Tag must not contain empty segments';
    if (RegExp(r'\s').hasMatch(seg)) {
      return 'Tag segment must not contain whitespace';
    }
  }

  return null;
}

/// Replace every occurrence of [oldPath] with [newPath] across a map of
/// document id → tag set.
///
/// Returns a new map keyed by document id containing **only** entries whose
/// tag set actually changed.  Tags are replaced in place (order of the
/// original list is preserved) and deduplicated — if [newPath] already
/// existed in the set, only one copy remains.
///
/// If [oldPath] == [newPath] the returned map is empty (no-op).
Map<String, Set<String>> renamedTagsByDoc(
  Map<String, Set<String>> tagsByDoc,
  String oldPath,
  String newPath,
) {
  if (oldPath == newPath) return {};

  final result = <String, Set<String>>{};

  for (final entry in tagsByDoc.entries) {
    final tags = entry.value;
    if (!tags.contains(oldPath)) continue;

    // Preserve order by iterating through a list; dedupe newPath.
    final newTags = <String>[];
    var newPathAdded = false;
    for (final t in tags) {
      if (t == oldPath) {
        if (!newPathAdded) {
          newTags.add(newPath);
          newPathAdded = true;
        }
      } else {
        newTags.add(t);
      }
    }
    if (!newPathAdded) newTags.add(newPath);

    result[entry.key] = Set<String>.of(newTags);
  }

  return result;
}
