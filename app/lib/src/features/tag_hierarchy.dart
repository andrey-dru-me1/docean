/// Hierarchy-aware tag operations for documents.
///
/// Tags may be slash-separated paths: tag `study/mit/machine-learning`
/// conceptually represents `study`, `study/mit`, and `study/mit/machine-learning`.
/// Documents store ONLY explicitly-set tag strings; parents are DERIVED.
///
/// Terminology: a *dirtag* is a tag with at least one derived sub-tag; a
/// *sub-tag* is a non-first-segment relationship; a *leaf* has no sub-tags;
/// *top-level* means the first segment.
///
/// IMPORTANT: tags containing `:` (property/scope tags such as
/// `student:Alice` or `scope:diploma`) belong to a separate property system
/// and are IGNORED by every function in this library. They are filtered out
/// at the entry points.
library;

/// The set of tags of one document, keyed by document id.
typedef TagsByDoc = Map<String, Set<String>>;

/// Matches a single tag segment (same charset as file naming).
final RegExp _segmentPattern = RegExp(r'^[A-Za-z0-9._ -]+$');

/// Maximum number of segments in a tag path.
const int _maxSegments = 8;

/// Maximum length of a single tag segment.
const int _maxSegmentLength = 60;

/// Returns the implicit ancestors of [tag]: every proper prefix path.
///
/// `'a/b/c'` returns `['a', 'a/b']`. Throws [ArgumentError] when [tag] is
/// empty or contains an empty segment (e.g. `'a//b'`).
List<String> implicitAncestors(String tag) {
  final segments = tag.split('/');
  if (tag.isEmpty || segments.any((s) => s.isEmpty)) {
    throw ArgumentError.value(tag, 'tag', 'Tag path must be non-empty with no empty segments');
  }
  final result = <String>[];
  final buffer = StringBuffer();
  for (var i = 0; i < segments.length - 1; i++) {
    if (i > 0) {
      buffer.write('/');
    }
    buffer.write(segments[i]);
    result.add(buffer.toString());
  }
  return result;
}

/// Whether [tag] is a valid tag path: non-empty, every segment matches
/// `[A-Za-z0-9._ -]+`, no leading/trailing/double slashes, at most 8
/// segments, and each segment at most 60 characters long.
bool isValidTagPath(String tag) => validateTagPath(tag) == null;

/// Returns `null` when [tag] is a valid tag path, otherwise a
/// human-readable error message.
String? validateTagPath(String tag) {
  if (tag.isEmpty) {
    return 'Tag must not be empty';
  }
  if (tag.startsWith('/')) {
    return 'Tag must not start with a slash';
  }
  if (tag.endsWith('/')) {
    return 'Tag must not end with a slash';
  }
  if (tag.contains('//')) {
    return 'Tag must not contain double slashes';
  }
  final segments = tag.split('/');
  if (segments.length > _maxSegments) {
    return 'Tag must have at most $_maxSegments segments';
  }
  for (final segment in segments) {
    if (segment.length > _maxSegmentLength) {
      return 'Segment must be at most $_maxSegmentLength characters';
    }
    if (!_segmentPattern.hasMatch(segment)) {
      return 'Segment contains invalid characters';
    }
  }
  return null;
}

/// Whether [tag] is hierarchical, i.e. contains a `/`.
bool isHierarchical(String tag) => tag.contains('/');

/// Returns the first segment of [tag].
String topLevelOf(String tag) => tag.split('/').first;

/// Returns the parent path of [tag], or `''` when [tag] is top-level.
String parentOf(String tag) {
  final slash = tag.lastIndexOf('/');
  return slash == -1 ? '' : tag.substring(0, slash);
}

/// Returns the last segment of [tag].
String lastSegmentOf(String tag) => tag.split('/').last;

/// Whether [tag] is a dirtag: some OTHER tag in [allTags] starts with
/// `'$tag/'`. Property tags in [allTags] are ignored.
bool isDirtag(String tag, Iterable<String> allTags) {
  final prefix = '$tag/';
  return allTags.any((t) => !t.contains(':') && t.startsWith(prefix));
}

/// Returns the implicit tag set of [tag]: the tag itself plus all its
/// ancestors. NOT to be stored — used for logic.
///
/// `'a/b/c'` returns `{'a/b/c', 'a/b', 'a'}`.
Set<String> implicitTagSet(String tag) => {
      ...implicitAncestors(tag),
      tag,
    };

/// The union of [implicitTagSet] for every stored (non-property) tag across
/// [tagsByDoc]. Used as the known-tag universe for dirtag detection.
Set<String> _derivedUniverse(TagsByDoc tagsByDoc) {
  final universe = <String>{};
  for (final tags in tagsByDoc.values) {
    for (final tag in tags) {
      if (tag.contains(':')) {
        continue;
      }
      universe.addAll(implicitTagSet(tag));
    }
  }
  return universe;
}

/// Hierarchy-aware containment: [docTags] contains [path] exactly or any
/// tag starting with `'$path/'`. Property tags in [docTags] are ignored.
bool docContained(Set<String> docTags, String path) {
  final prefix = '$path/';
  for (final tag in docTags) {
    if (tag.contains(':')) {
      continue;
    }
    if (tag == path || tag.startsWith(prefix)) {
      return true;
    }
  }
  return false;
}

/// Number of docs in [tagsByDoc] contained by [path].
int containedCount(String path, TagsByDoc tagsByDoc) =>
    containedDocIds(path, tagsByDoc).length;

/// Ids of docs in [tagsByDoc] contained by [path].
Set<String> containedDocIds(String path, TagsByDoc tagsByDoc) {
  final result = <String>{};
  for (final entry in tagsByDoc.entries) {
    if (docContained(entry.value, path)) {
      result.add(entry.key);
    }
  }
  return result;
}

/// Distinct next segments of tags starting with `'$path/'` across all docs.
///
/// Sorted: dirtags first (containedCount desc, then name asc), then leaves
/// (name asc).
///
/// NOTE: the product spec's worked example ("only 'ml' shows under
/// study/mit") is internally inconsistent — knn and qsort are symmetric with
/// respect to study/mit. This implementation follows the consistent prefix
/// rule and yields `[cprog, ml]` for `directSubTags('study/mit')`.
List<String> directSubTags(String path, TagsByDoc tagsByDoc) {
  final universe = _derivedUniverse(tagsByDoc);
  final prefix = '$path/';
  final candidates = <String>{};
  for (final tag in universe) {
    if (tag.startsWith(prefix)) {
      candidates.add(tag.substring(prefix.length).split('/').first);
    }
  }
  final dirtags = <String>[];
  final leaves = <String>[];
  for (final next in candidates) {
    final full = '$path/$next';
    if (isDirtag(full, universe)) {
      dirtags.add(next);
    } else {
      leaves.add(next);
    }
  }
  dirtags.sort((a, b) {
    final byCount =
        containedCount('$path/$b', tagsByDoc).compareTo(
          containedCount('$path/$a', tagsByDoc),
        );
    return byCount != 0 ? byCount : a.compareTo(b);
  });
  leaves.sort();
  return [...dirtags, ...leaves];
}

/// All top-level segments across [tagsByDoc], with the same sort rule as
/// [directSubTags]: dirtags first (containedCount desc, then name asc), then
/// leaves (name asc).
List<String> topLevelTags(TagsByDoc tagsByDoc) {
  final universe = _derivedUniverse(tagsByDoc);
  final tops = <String>{};
  for (final tag in universe) {
    tops.add(topLevelOf(tag));
  }
  final dirtags = <String>[];
  final leaves = <String>[];
  for (final top in tops) {
    if (isDirtag(top, universe)) {
      dirtags.add(top);
    } else {
      leaves.add(top);
    }
  }
  dirtags.sort((a, b) {
    final byCount = containedCount(b, tagsByDoc).compareTo(
      containedCount(a, tagsByDoc),
    );
    return byCount != 0 ? byCount : a.compareTo(b);
  });
  leaves.sort();
  return [...dirtags, ...leaves];
}

/// Docs whose tag set contains EXACTLY [path] (direct assignment only).
Set<String> directlyAssignedDocIds(String path, TagsByDoc tagsByDoc) {
  final result = <String>{};
  for (final entry in tagsByDoc.entries) {
    if (entry.value.contains(path)) {
      result.add(entry.key);
    }
  }
  return result;
}

/// Match tier for [query] against a single known tag, or `null` when there
/// is no match. Tiers: 1 exact, 2 full-path prefix, 3 segment prefix,
/// 4 subsequence over the flattened path.
int? _matchTier(String query, String lowerTag) {
  if (lowerTag == query) {
    return 1;
  }
  if (lowerTag.startsWith(query)) {
    return 2;
  }
  if (lowerTag.split('/').any((s) => s.startsWith(query))) {
    return 3;
  }
  final flat = lowerTag.replaceAll('/', '');
  if (_isSubsequence(query, flat)) {
    return 4;
  }
  return null;
}

/// Whether [needle] is a subsequence of [haystack].
bool _isSubsequence(String needle, String haystack) {
  var i = 0;
  for (var j = 0; j < haystack.length && i < needle.length; j++) {
    if (needle.codeUnitAt(i) == haystack.codeUnitAt(j)) {
      i++;
    }
  }
  return i == needle.length;
}

/// Ranked completion suggestions for [query] against known tags (full stored
/// paths). Property tags in [allTags] are ignored.
///
/// Match tiers (case-insensitive):
/// 1. exact full path;
/// 2. full-path prefix (`'study/mit'` prefix of `'study/mit/ml'`);
/// 3. segment prefix (`'machine-le'` prefix of segment `'machine-learning'`);
/// 4. subsequence over the path with all `/` removed (`'smitml'` is a
///    subsequence of `'studymitmachinelearning'`).
///
/// Rank = tier, then shorter path first, then alphabetical. Dedup.
/// Empty or whitespace-only [query] returns `[]`.
List<String> suggestTagCompletions(
  String query,
  Iterable<String> allTags, {
  int limit = 8,
}) {
  final trimmed = query.trim();
  if (trimmed.isEmpty || limit <= 0) {
    return const [];
  }
  final q = trimmed.toLowerCase();
  final tiers = [<String>[], <String>[], <String>[], <String>[]];
  for (final tag in allTags) {
    if (tag.contains(':')) {
      continue;
    }
    final tier = _matchTier(q, tag.toLowerCase());
    if (tier != null) {
      tiers[tier - 1].add(tag);
    }
  }
  final result = <String>[];
  for (final tier in tiers) {
    tier.sort((a, b) {
      final byLength = a.length.compareTo(b.length);
      return byLength != 0 ? byLength : a.compareTo(b);
    });
    for (final tag in tier) {
      result.add(tag);
      if (result.length == limit) {
        return result;
      }
    }
  }
  return result;
}

/// Rename planner: for every doc containing EXACTLY [oldPath], produces the
/// new tag set. [newPath] replaces [oldPath] at its original position
/// (insertion order is preserved); when [newPath] already exists on the doc,
/// it stays at its earlier position and [oldPath] is simply dropped. Other
/// tags, including property tags, are preserved.
///
/// Docs without [oldPath] are absent from the result. A no-op rename
/// ([oldPath] == [newPath]) yields an empty map. An invalid [newPath] throws
/// [ArgumentError].
Map<String, Set<String>> renamedTagsByDoc(
  TagsByDoc tagsByDoc,
  String oldPath,
  String newPath,
) {
  if (oldPath == newPath) {
    return {};
  }
  final error = validateTagPath(newPath);
  if (error != null) {
    throw ArgumentError.value(newPath, 'newPath', error);
  }
  final result = <String, Set<String>>{};
  for (final entry in tagsByDoc.entries) {
    if (!entry.value.contains(oldPath)) {
      continue;
    }
    final next = <String>{};
    for (final tag in entry.value) {
      if (tag == oldPath) {
        // Positional substitution; skip when newPath already sits earlier in
        // the set (dedupe keeps the earlier slot).
        if (!next.contains(newPath)) {
          next.add(newPath);
        }
      } else {
        next.add(tag);
      }
    }
    result[entry.key] = next;
  }
  return result;
}