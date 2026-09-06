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
        topLevelOf,
        topLevelTags;
import 'document_view.dart' show DocumentSummary;
import 'widgets.dart' show EmptyState, tagColorFor;

/// The "Tags" view mode: a collapsible tree of the documents' tag hierarchy.
///
/// Tags form a tree via `/`-separated paths (`study/mit/ml` nests under
/// `study/mit` under `study`). Each node row shows the tag's last segment; a
/// sub-tag additionally renders its direct parent's name vertically (rotated
/// 90°) to the left of the chip, with indentation implying the ancestors.
/// Directory tags (tags with children) carry a right-aligned count badge with
/// the number of documents contained in the subtree, and every node can expand
/// to reveal its children (dirtags) and then its directly-assigned documents.
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

  /// Appends [path]'s node row; when expanded, its direct sub-tags (recursed
  /// at depth+1) followed by its directly-assigned documents as leaf rows.
  void _appendNode(
    List<Widget> rows,
    String path,
    int depth,
    TagsByDoc tagsByDoc,
  ) {
    rows.add(_buildTagRow(path, depth, tagsByDoc));
    if (!_expandedTagPaths.contains(path)) return;
    for (final sub in directSubTags(path, tagsByDoc)) {
      _appendNode(rows, sub, depth + 1, tagsByDoc);
    }
    for (final id in directlyAssignedDocIds(path, tagsByDoc)) {
      final doc = _byId[id];
      if (doc != null) {
        rows.add(_buildDocumentRow(doc, depth + 1));
      }
    }
  }

  Widget _buildTagRow(String path, int depth, TagsByDoc tagsByDoc) {
    final scheme = Theme.of(context).colorScheme;
    final expanded = _expandedTagPaths.contains(path);
    final isDir = isDirtag(path, _allTagPaths(tagsByDoc));
    final label = lastSegmentOf(path);
    final color = tagColorFor(topLevelOf(path));
    // Sub-tag rows (any tag with a parent) name the direct parent vertically
    // to the left of the chip; indentation implies the rest of the chain.
    final parentName = depth > 0 ? lastSegmentOf(parentOf(path)) : null;

    final chip = _TagPill(label: label, color: color);

    return InkWell(
      key: ValueKey('tag-node-$path'),
      onTap: () => _toggleExpanded(path),
      child: Padding(
        padding: EdgeInsets.only(left: (depth * 20).toDouble()),
        child: Row(
          children: [
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
            if (parentName != null) ...[
              RotatedBox(
                quarterTurns: 1,
                child: Text(
                  parentName,
                  style: TextStyle(
                    fontSize: 9,
                    height: 1,
                    color: scheme.outline,
                  ),
                ),
              ),
              const SizedBox(width: 4),
            ],
            chip,
            if (isDir) ...[
              const Spacer(),
              _CountBadge(
                key: ValueKey('tag-count-$path'),
                count: containedCount(path, tagsByDoc),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildDocumentRow(DocumentSummary doc, int depth) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      key: ValueKey('tag-doc-${doc.id}'),
      onTap: () => widget.onOpenDocument(doc),
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

/// A compact colored tag pill matching [TagChip]'s visuals but with an
/// EXPLICIT color (the top-level ancestor's color for hierarchical tags).
class _TagPill extends StatelessWidget {
  const _TagPill({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      curve: Curves.easeOut,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Color.lerp(color, Colors.white, 0.12)!),
      ),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          fontSize: 11.5,
          color: Colors.white,
          fontWeight: FontWeight.w600,
          height: 1,
          shadows: [Shadow(color: Colors.black45, blurRadius: 3)],
        ),
      ),
    );
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