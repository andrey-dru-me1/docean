import 'package:flutter/material.dart';

import '../features/tag_hierarchy.dart'
    show
        TagsByDoc,
        containedCount,
        directSubTags,
        directlyAssignedDocIds,
        isDirtag,
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
const double _kGutterColumnWidth = 16;

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
    for (final top in topLevelTags(tagsByDoc)) {
      _appendNode(rows, top, 0, tagsByDoc);
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

  /// Appends [path]'s node row; when expanded, renders its subtag subtree via
  /// [_appendSubtree].
  void _appendNode(
    List<Widget> rows,
    String path,
    int depth,
    TagsByDoc tagsByDoc,
  ) {
    rows.add(_buildTagRow(path, depth, tagsByDoc));
    if (!_expandedTagPaths.contains(path)) return;
    _appendSubtree(rows, path, depth + 1, tagsByDoc);
  }

  /// Renders the subtag rows of the EXPANDED node [path] at [depth].
  ///
  /// Expanded sub-tags keep their navigational row and recurse one level
  /// deeper; after all expanded child sections, [path]'s OWN subtag section
  /// (its remaining sub-tags + directly-assigned documents) lands one level
  /// deeper than the plain rows whenever a child section unwound — so the
  /// previously selected tag's context stays visible at the deepest level,
  /// every section row labeled `(owner) > full/path`.
  void _appendSubtree(
    List<Widget> rows,
    String path,
    int depth,
    TagsByDoc tagsByDoc,
  ) {
    final subs = directSubTags(path, tagsByDoc);
    var anyChildExpanded = false;
    for (final sub in subs) {
      final child = '$path/$sub';
      if (!_expandedTagPaths.contains(child)) continue;
      // Only EXPANDED sub-tags keep their navigational row; everything else
      // is rendered once, inside this tag's own labeled section below.
      anyChildExpanded = true;
      rows.add(_buildTagRow(child, depth, tagsByDoc));
      _appendSubtree(rows, child, depth + 1, tagsByDoc);
    }
    final ownDepth = depth + (anyChildExpanded ? 1 : 0);
    for (final sub in subs) {
      final child = '$path/$sub';
      if (_expandedTagPaths.contains(child)) continue;
      rows.add(
        _buildSectionRow(child, owner: path, depth: ownDepth, tagsByDoc: tagsByDoc),
      );
    }
    for (final id in directlyAssignedDocIds(path, tagsByDoc)) {
      final doc = _byId[id];
      if (doc != null) {
        rows.add(_buildDocumentRow(doc, ownDepth));
      }
    }
  }

  /// A labeled sub-tag row inside a section: `(owner) > full/path` as
  /// colorful text, chevron affordance when the tag is a dirtag, no count
  /// badge (the badge lives on navigational dirtag rows). Tapping toggles
  /// expansion like any other row.
  Widget _buildSectionRow(
    String path, {
    required String owner,
    required int depth,
    required TagsByDoc tagsByDoc,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final isDir = isDirtag(path, _allTagPaths(tagsByDoc));

    return GestureDetector(
      key: ValueKey('tag-section-$path'),
      onTap: () => _toggleExpanded(path),
      behavior: HitTestBehavior.opaque,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: SizedBox(
          height: _kTagRowHeight,
          child: Row(
            children: [
              _buildGutter(path, depth),
              SizedBox(width: (depth * 20).toDouble()),
              AnimatedRotation(
                turns: _expandedTagPaths.contains(path) ? 0.25 : 0,
                duration: const Duration(milliseconds: 150),
                child: isDir
                    ? Icon(
                        Icons.expand_more,
                        size: 18,
                        color: scheme.onSurfaceVariant,
                      )
                    : const SizedBox(width: 18),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Text.rich(
                  TextSpan(
                    style: const TextStyle(height: 1),
                    children: [
                      TextSpan(
                        text: '(${lastSegmentOf(owner)}) > ',
                        style: TextStyle(
                          color: scheme.outline,
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      ..._pathSpans(path),
                    ],
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTagRow(String path, int depth, TagsByDoc tagsByDoc) {
    final scheme = Theme.of(context).colorScheme;
    final expanded = _expandedTagPaths.contains(path);
    final isDir = isDirtag(path, _allTagPaths(tagsByDoc));

    return GestureDetector(
      key: ValueKey('tag-node-$path'),
      onTap: () => _toggleExpanded(path),
      behavior: HitTestBehavior.opaque,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: SizedBox(
          height: _kTagRowHeight,
          child: Row(
            children: [
              // IDE-style ancestor gutter: one 16px column per ancestor level.
              _buildGutter(path, depth),
              // Content indent after the gutter (depth * 20, as before).
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
              Expanded(child: _buildColorfulPath(path)),
              if (isDir) ...[
                const SizedBox(width: 8),
                _CountBadge(
                  key: ValueKey('tag-count-$path'),
                  count: containedCount(path, tagsByDoc),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// The colorful spans of [path]: segment i tinted with the color of its
  /// cumulative prefix (`study`, `study/mit`, ...), joined by a muted ` / `.
  List<TextSpan> _pathSpans(String path) {
    final scheme = Theme.of(context).colorScheme;
    final segments = path.split('/');
    final spans = <TextSpan>[];
    for (var i = 0; i < segments.length; i++) {
      if (i > 0) {
        spans.add(
          TextSpan(
            text: ' / ',
            style: TextStyle(
              color: scheme.outline,
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
            ),
          ),
        );
      }
      spans.add(
        TextSpan(
          text: segments[i],
          style: TextStyle(
            color: tagColorFor(segments.sublist(0, i + 1).join('/')),
            fontSize: 12.5,
            fontWeight: FontWeight.w600,
          ),
        ),
      );
    }
    return spans;
  }

  /// The row's FULL path rendered as colorful text (see [_pathSpans]).
  Widget _buildColorfulPath(String path) {
    return Text.rich(
      TextSpan(style: const TextStyle(height: 1), children: _pathSpans(path)),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }

  /// The IDE-style gutter shown left of the chevron for sub-tag rows
  /// (depth > 0): one `_kGutterColumnWidth`-wide column per ancestor level,
  /// each drawing a 2px vertical guide line tinted with that ancestor's own
  /// color; the LAST column (the direct parent) additionally shows a rotated
  /// pill naming the parent's last segment. Total width = depth × column width.
  Widget _buildGutter(String path, int depth) {
    if (depth == 0) return const SizedBox.shrink();
    final segments = path.split('/');
    final parentPath = parentOf(path);
    final parentLabel = lastSegmentOf(parentPath);

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
                      color: tagColorFor(
                        segments.sublist(0, i).join('/'),
                      ).withValues(alpha: 0.45),
                    ),
                  ),
                  if (i == depth)
                    Center(
                      child: RotatedBox(
                        quarterTurns: 1,
                        child: Container(
                          key: ValueKey('tag-parent-pill-$parentPath'),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 2,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: tagColorFor(parentPath),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            parentLabel,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 9,
                              height: 1,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildDocumentRow(DocumentSummary doc, int depth) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      key: ValueKey('tag-doc-${doc.id}'),
      onTap: () => widget.onOpenDocument(doc),
      behavior: HitTestBehavior.opaque,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Padding(
          padding: EdgeInsets.only(left: (depth * 20 + 22).toDouble(), right: 8),
          child: Row(
            children: [
              Icon(
                Icons.description_outlined,
                size: 16,
                color: scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 8),
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
        _expandedTagPaths.addAll(_allTagPaths(_tagsByDoc));
        _allExpanded = true;
      }
    });
  }

  /// Union of every tag path (including derived ancestors) on the current
  /// document set, used for dirtag detection.
  Set<String> _allTagPaths(TagsByDoc tagsByDoc) {
    final paths = <String>{for (final tags in tagsByDoc.values) ...tags};
    for (final tags in tagsByDoc.values) {
      for (final t in tags) {
        var p = t;
        while (p.contains('/')) {
          p = p.substring(0, p.lastIndexOf('/'));
          paths.add(p);
        }
      }
    }
    return paths;
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