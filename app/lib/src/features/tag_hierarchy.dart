/// Tag-path utilities for the tag hierarchy tree view.
///
/// Tags form a hierarchy through `/`-separated paths (e.g. `study/mit/ml` is a
/// child of `study/mit`, which is a child of `study`). Property/scope tags
/// (`key:value`) are not tag paths and are ignored by every function here.
library;

typedef TagsByDoc = Map<String, Set<String>>;

/// Whether [tag] can be part of a tag hierarchy: non-empty, contains no `:`
/// (property/scope tags are excluded) and has no empty path segment.
bool isValidTagPath(String tag) => validateTagPath(tag) == null;

/// A human-readable reason [tag] is not a valid tag path, or `null` when it is.
String? validateTagPath(String tag) {
  if (tag.isEmpty) return 'Tag path is empty';
  if (tag.contains(':')) return 'Property/scope tags are not tag paths';
  if (tag.startsWith('/') || tag.endsWith('/') || tag.contains('//')) {
    return 'Tag path contains an empty segment';
  }
  return null;
}

/// Whether [tag] is a hierarchical path (contains at least one `/`).
bool isHierarchical(String tag) => tag.contains('/');

/// The first (top-level) segment of [tag].
String topLevelOf(String tag) => tag.split('/').first;

/// The parent path of [tag] (everything before the last `/`), or `''` when
/// [tag] is top-level.
String parentOf(String tag) {
  final i = tag.lastIndexOf('/');
  return i < 0 ? '' : tag.substring(0, i);
}

/// The last (display) segment of [tag].
String lastSegmentOf(String tag) => tag.split('/').last;

/// Whether [tag] is a "directory" tag: some tag in [allTags] hangs beneath it
/// (`$tag/...`).
bool isDirtag(String tag, Iterable<String> allTags) {
  final prefix = '$tag/';
  return allTags.any((t) => t.startsWith(prefix));
}

/// Every tag path (including derived ancestors) present across [tagsByDoc].
Set<String> _allTagPaths(TagsByDoc tagsByDoc) {
  final paths = <String>{};
  for (final tags in tagsByDoc.values) {
    for (final t in tags) {
      if (!isValidTagPath(t)) continue;
      paths.add(t);
      var p = t;
      while (p.contains('/')) {
        p = p.substring(0, p.lastIndexOf('/'));
        paths.add(p);
      }
    }
  }
  return paths;
}

/// Whether the document tagged [docTags] is contained in [path]: it carries
/// [path] itself or a descendant (`$path/...`).
bool docContained(Set<String> docTags, String path) =>
    docTags.any((t) => t == path || t.startsWith('$path/'));

/// Number of documents contained in [path] (tagged [path] or a descendant).
int containedCount(String path, TagsByDoc tagsByDoc) =>
    tagsByDoc.values.where((tags) => docContained(tags, path)).length;

/// IDs of documents contained in [path].
Set<String> containedDocIds(String path, TagsByDoc tagsByDoc) => {
      for (final e in tagsByDoc.entries)
        if (docContained(e.value, path)) e.key,
    };

/// IDs of documents tagged [path] exactly.
Set<String> directlyAssignedDocIds(String path, TagsByDoc tagsByDoc) => {
      for (final e in tagsByDoc.entries)
        if (e.value.any((t) => t == path)) e.key,
    };

/// Sort tag rows: dirtags first (by containedCount desc, then name asc),
/// then leaves (name asc).
List<String> _sortedTagRows(
  List<String> tags,
  TagsByDoc tagsByDoc,
  Set<String> allTags,
) {
  final dirtags = tags.where((t) => isDirtag(t, allTags)).toList()
    ..sort((a, b) {
      final c =
          containedCount(b, tagsByDoc).compareTo(containedCount(a, tagsByDoc));
      return c != 0 ? c : a.compareTo(b);
    });
  final leaves = tags.where((t) => !isDirtag(t, allTags)).toList()..sort();
  return [...dirtags, ...leaves];
}

/// The direct children of [path] (tags whose parent is [path]), dirtags first
/// then leaves.
List<String> directSubTags(String path, TagsByDoc tagsByDoc) {
  final allTags = _allTagPaths(tagsByDoc);
  final children = allTags.where((t) => parentOf(t) == path).toList();
  return _sortedTagRows(children, tagsByDoc, allTags);
}

/// The top-level tags (direct children of the root), dirtags first then leaves.
List<String> topLevelTags(TagsByDoc tagsByDoc) {
  final allTags = _allTagPaths(tagsByDoc);
  final tops = allTags.where((t) => parentOf(t) == '').toList();
  return _sortedTagRows(tops, tagsByDoc, allTags);
}

/// Tag completions whose path or last segment starts with [query].
List<String> suggestTagCompletions(
  String query,
  Iterable<String> allTags, {
  int limit = 10,
}) {
  final q = query.trim().toLowerCase();
  final matches = allTags
      .where((t) =>
          isValidTagPath(t) &&
          (t.toLowerCase().startsWith(q) ||
              lastSegmentOf(t).toLowerCase().startsWith(q)))
      .toSet()
      .toList()
    ..sort();
  return limit > 0 ? matches.take(limit).toList() : matches;
}

/// A copy of [tagsByDoc] with [oldPath] (and its descendants) renamed to
/// [newPath] on every document.
Map<String, Set<String>> renamedTagsByDoc(
  TagsByDoc tagsByDoc,
  String oldPath,
  String newPath,
) => {
      for (final e in tagsByDoc.entries)
        e.key: {
          for (final t in e.value)
            if (t == oldPath)
              newPath
            else if (t.startsWith('$oldPath/'))
              '$newPath${t.substring(oldPath.length)}'
            else
              t,
        },
    };
