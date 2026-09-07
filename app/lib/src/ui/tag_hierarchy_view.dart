import 'package:flutter/material.dart';

import '../features/tag_hierarchy.dart'
    show
        TagsByDoc,
        childTags,
        docAtPath,
        docsContaining,
        isValidTagPath,
        lastSegmentOf,
        parentOf,
        topLevelTags;
import 'document_view.dart' show DocumentSummary;
import 'widgets.dart' show EmptyState, tagColorFor;

/// The "Tags" view mode: a collapsible tree of the documents' tag hierarchy.
///
/// Tags form a tree via `/`-separated paths (`study/mit/ml` nests under
/// `study/mit` under `study`). Each tag row renders its FULL path as colorful
/// text (one color per cumulative prefix); a sub-tag row additionally draws an
/// IDE-style gutter to its left: one 16px guide-line column per ancestor level
/// (each line tinted with that ancestor's own color), with the direct parent's
/// name shown as a rotated pill in the last column. Directory tags (tags with
/// children) carry a right-aligned count badge with the number of documents
/// contained in the subtree, and every node can expand to reveal its children
/// (dirtags) and then its directly-assigned documents.
///
/// Expansion state is keyed by the FULL tag path, so a previously-expanded
/// sub-tag re-expands after a parent collapse/expand cycle.
class TagHierarchyView extends StatefulWidget {
  const TagHierarchyView({
    super.key,
    required this.documents,
    required this.onOpenDocument,
  });

  /// The currently filtered documents to build the tag tree from.
  final List<DocumentSummary> documents;

  /// Called when a document leaf row is tapped.
  final void Function(DocumentSummary) onOpenDocument;

  @override
  State<TagHierarchyView> createState() => _TagHierarchyViewState();
}

/// Fixed row height of a tag row so the guide lines can span the full row.
const double _kTagRowHeight = 28;

/// Width of one gutter column (one ancestor level).
const double _kGutterColumnWidth = 30;

/// Joins a path's component tag names into the expansion/row key. A control
/// character on purpose: validated tag names can never contain one, so the
/// join is unambiguous even though component names themselves contain `/`.
const String _kPathSeparator = '\u0000';

class _TagHierarchyViewState extends State<TagHierarchyView> {
  /// Expanded tag paths, keyed by FULL path so sub-tags stay expanded across
  /// parent collapse/expand cycles.
  final Set<String> _expandedTagPaths = {};

  bool _allExpanded = false;

  /// id → its documents, so leaf rows can hand the real [DocumentSummary] to
  /// [TagHierarchyView.onOpenDocument].
  Map<String, DocumentSummary> get _byId => {
        for (final doc in widget.documents) doc.id: doc,
      };

  /// TagsByDoc for the current documents. Property/scope tags (containing
  /// `:`) and documents with no remaining valid tags are skipped.
  TagsByDoc get _tagsByDoc {
    final tagsByDoc = <String, Set<String>>{};
    for (final doc in widget.documents) {
      final tags = <String>{for (final t in doc.tags) if (isValidTagPath(t)) t};
      if (tags.isEmpty) continue;
      tagsByDoc[doc.id] = tags;
    }
    return tagsByDoc;
  }

  @override
  Widget build(BuildContext context) {
    final tagsByDoc = _tagsByDoc;
    if (tagsByDoc.isEmpty) {
      return const EmptyState(icon: Icons.tag, title: 'No tags yet');
    }
    final rows = <Widget>[];
    // One rendered-set for the WHOLE tree: the same walk can never be laid
    // out twice. Paths are ORDER-SENSITIVE component walks — the same tag set
    // reached via a different order is a different (also valid) walk.
    final rendered = <String>{};
    for (final top in topLevelTags(tagsByDoc)) {
      _appendNode(rows, [top], tagsByDoc, rendered: rendered);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildHeader(context),
        const Divider(height: 1),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            children: rows,
          ),
        ),
      ],
    );
  }

  /// Appends the node row for [components]; when expanded, renders its
/// children via [_appendChildren] and defers its own documents below them.
void _appendNode(
    List<Widget> rows,
    List<String> components,
    TagsByDoc tagsByDoc, {
    required Set<String> rendered,
  }) {
    final pathKey = components.join(_kPathSeparator);
    if (!rendered.add(pathKey)) return;
    rows.add(_buildTagRow(components, pathKey, tagsByDoc));
    if (!_expandedTagPaths.contains(pathKey)) return;
    // The ROOT expanded tag's own files move below every subtag section;
    // files of nested expanded directories stay right below their own
    // children (nested nodes pass a FRESH deferred list, landing inline).
    final deferredDocs = <Widget>[];
    _appendChildren(
      rows, components, pathKey, tagsByDoc,
      rendered: rendered, deferredDocs: deferredDocs,
    );
    rows.addAll(deferredDocs);
  }

  /// The child rows (and directly-assigned documents) of the EXPANDED node
  /// [components].
  ///
  /// Children are the tags that EXTEND the path: every tag carried by a
  /// document whose tag set contains all the path's components — NOT just
  /// prefix-tree subtags. Siblings therefore stay visible when one child is
  /// expanded, the same tag may appear on several depth levels, and mixed
  /// paths (`p1/p2/p2s1/p1s2`) are walkable. A document is listed under the
  /// path only when its materialized tag set is EXACTLY the path's component
  /// set. Nested nodes defer with a fresh list so their files land inline;
  /// the root's list accumulates below everything.
  void _appendChildren(
    List<Widget> rows,
    List<String> components,
    String pathKey,
    TagsByDoc tagsByDoc, {
    required Set<String> rendered,
    required List<Widget> deferredDocs,
  }) {
    for (final t in childTags(components, tagsByDoc)) {
      final childComponents = [...components, t];
      final childKey = childComponents.join(_kPathSeparator);
      if (!rendered.add(childKey)) continue;
      rows.add(_buildTagRow(childComponents, childKey, tagsByDoc));
      if (_expandedTagPaths.contains(childKey)) {
        final nestedDeferred = <Widget>[];
        _appendChildren(
          rows, childComponents, childKey, tagsByDoc,
          rendered: rendered, deferredDocs: nestedDeferred,
        );
        rows.addAll(nestedDeferred);
      }
    }
    final comps = components.toSet();
    for (final id in docsContaining(comps, tagsByDoc)) {
      final docTags = tagsByDoc[id];
      final doc = _byId[id];
      if (doc == null || docTags == null || !docAtPath(docTags, comps)) {
        continue;
      }
      deferredDocs.add(
        _buildDocumentRow(
          doc,
          depth: components.length,
          ownerComponents: components,
          pathKey: pathKey,
        ),
      );
    }
  }

  /// A tag row for the path [components] (walk key [pathKey]): colorful
  /// per-component text, IDE gutter, chevron, and a badge with the number of
  /// documents reachable through this directory.
  Widget _buildTagRow(
    List<String> components,
    String pathKey,
    TagsByDoc tagsByDoc,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final expanded = _expandedTagPaths.contains(pathKey);
    final depth = components.length - 1;
    final count = docsContaining(components.toSet(), tagsByDoc).length;

    return GestureDetector(
      key: ValueKey('tag-node-$pathKey'),
      onTap: () => _toggleExpanded(pathKey),
      behavior: HitTestBehavior.opaque,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: SizedBox(
          height: _kTagRowHeight,
          child: Row(
            children: [
              _buildGutter(components, depth),
              SizedBox(width: (depth * 20).toDouble()),
              AnimatedRotation(
                turns: expanded ? 0.25 : 0,
                duration: const Duration(milliseconds: 150),
                child: Icon(
                  Icons.expand_more,
                  size: 18,
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(width: 4),
              Expanded(child: _buildColorfulPath(components)),
              const SizedBox(width: 8),
              _CountBadge(key: ValueKey('tag-count-$pathKey'), count: count),
            ],
          ),
        ),
      ),
    );
  }

  /// The row's appearance: ONLY the last tag of the path, tinted with that
  /// tag's own color (the walk prefix stays visible through the gutter
  /// pills/guide lines instead). Appearance only — behavior (keys, toggling,
  /// ordering) is untouched.
  List<TextSpan> _pathSpans(List<String> components) {
    final last = components.last;
    return [
      TextSpan(
        text: lastSegmentOf(last),
        style: TextStyle(
          color: tagColorFor(last),
          fontSize: 12.5,
          fontWeight: FontWeight.w600,
        ),
      ),
    ];
  }

  /// The row's FULL path rendered as colorful text (see [_pathSpans]).
  Widget _buildColorfulPath(List<String> components) {
    return Text.rich(
      TextSpan(style: const TextStyle(height: 1), children: _pathSpans(components)),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }

  /// The IDE-style gutter shown left of the chevron for nested rows
  /// (depth > 0): one `_kGutterColumnWidth`-wide column per walk ancestor
  /// level, each drawing a 2px vertical guide line tinted with that walk
  /// ancestor tag's own color. The LAST column shows the row tag's REAL
  /// parent as a rotated pill — NOT the walk parent: in mixed walks they
  /// differ, and for `p1/p2/p2s1/p1s2` the pill of the `p1s2` row is `p1`.
  /// Rows whose tag is top-level have no real parent — the column keeps only
  /// its guide line.
  Widget _buildGutter(List<String> components, int depth, {Widget? lastColumn}) {
    if (depth == 0) return const SizedBox.shrink();
    final rowTag = components.last;
    final realParent = parentOf(rowTag);

    return SizedBox(
      width: (depth * _kGutterColumnWidth).toDouble(),
      height: double.infinity,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 1; i <= depth; i++)
            SizedBox(
              width: _kGutterColumnWidth,
              child: Stack(
                children: [
                  Positioned(
                    left: (_kGutterColumnWidth - 2) / 2,
                    top: 0,
                    bottom: 0,
                    child: Container(
                      key: ValueKey('tag-guide-$i'),
                      width: 2,
                      // Document rows may be deeper than their owner tag's
                      // chain; clamp the color index to the last component.
                      color: tagColorFor(
                        components[i.clamp(1, components.length) - 1],
                      ).withValues(alpha: 0.45),
                    ),
                  ),
                  if (i == depth)
                    Center(
                      child: lastColumn ??
                          (realParent.isEmpty
                              ? null
                              : RotatedBox(
                                  quarterTurns: 1,
                                  child: Container(
                                    key: ValueKey('tag-parent-pill-$realParent'),
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 2,
                                      vertical: 4,
                                    ),
                                    decoration: BoxDecoration(
                                      color: tagColorFor(realParent),
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: Text(
                                      lastSegmentOf(realParent),
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 9,
                                        height: 1,
                                      ),
                                    ),
                                  ),
                                )),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// A directly-assigned document row. Its icon sits in the gutter's LAST
  /// column — the same spot where tag rows show their rotated parent pill —
  /// with the ancestor guide lines continuing behind it.
  Widget _buildDocumentRow(
    DocumentSummary doc, {
    required int depth,
    required List<String> ownerComponents,
    required String pathKey,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      key: ValueKey('tag-doc-${doc.id}@$pathKey'),
      onTap: () => widget.onOpenDocument(doc),
      behavior: HitTestBehavior.opaque,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: SizedBox(
          height: _kTagRowHeight,
          child: Row(
            children: [
              _buildGutter(
                ownerComponents,
                depth,
                lastColumn: Icon(
                  Icons.description_outlined,
                  size: 14,
                  color: scheme.onSurfaceVariant,
                ),
              ),
              SizedBox(width: (depth * 20).toDouble()),
              Expanded(
                child: Text(
                  doc.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 4),
      child: Row(
        children: [
          Text(
            'Tags',
            style: Theme.of(
              context,
            ).textTheme.titleSmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
          const Spacer(),
          IconButton(
            key: const ValueKey('tag-tree-toggle-all'),
            tooltip: _allExpanded ? 'Collapse all' : 'Expand all',
            onPressed: _toggleAll,
            icon: Icon(
              _allExpanded ? Icons.unfold_less : Icons.unfold_more,
              size: 20,
            ),
          ),
        ],
      ),
    );
  }

  void _toggleExpanded(String path) {
    setState(() {
      if (!_expandedTagPaths.add(path)) _expandedTagPaths.remove(path);
    });
  }

  void _toggleAll() {
    setState(() {
      if (_allExpanded) {
        _expandedTagPaths.clear();
        _allExpanded = false;
      } else {
        _expandedTagPaths.addAll(_allPathKeys(_tagsByDoc));
        _allExpanded = true;
      }
    });
  }

  /// Expansion keys of EVERY walk in the lattice: the roots and, recursively,
  /// each walk extended by one child tag. Walks are finite — every step adds
  /// a tag that is not already in the path.
  Set<String> _allPathKeys(TagsByDoc tagsByDoc) {
    final keys = <String>{};
    void walk(List<String> components) {
      if (!keys.add(components.join(_kPathSeparator))) return;
      for (final t in childTags(components, tagsByDoc)) {
        walk([...components, t]);
      }
    }

    for (final top in topLevelTags(tagsByDoc)) {
      walk([top]);
    }
    return keys;
  }
}

/// A small right-aligned pill showing a contained-document count.
class _CountBadge extends StatelessWidget {
  const _CountBadge({super.key, required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Text(
        '$count',
        style: TextStyle(
          fontSize: 11.5,
          fontWeight: FontWeight.w600,
          color: scheme.onSurfaceVariant,
        ),
      ),
    );
  }
}