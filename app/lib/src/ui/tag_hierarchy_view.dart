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

/// Vertical gap between adjacent gutter segments (where the color changes).
const double _kGutterGap = 3;

/// Thickness of the horizontal serif strokes framing each segment.
const double _kSerifThickness = 2;

/// Horizontal half-width of a serif stroke (serif total width = 2 × this).
const double _kSerifHalfWidth = 4;

/// Joins a path's component tag names into the expansion/row key. A control
/// character on purpose: validated tag names can never contain one, so the
/// join is unambiguous even though component names themselves contain `/`.
const String _kPathSeparator = '\u0000';

/// One gutter SEGMENT: a vertical slice of a container's gutter with a
/// single color and a single marker (rotated pill OR document icon OR
/// nothing). Segments stack top-to-bottom inside the container's gutter.
class _GutterSegment {
  const _GutterSegment._({
    required this.color,
    required this.height,
    this.pillLabel,
    this.isDocIcon = false,
  });

  /// A segment with a rotated pill marker.
  factory _GutterSegment.pill({
    required Color color,
    required String label,
    required int height,
  }) =>
      _GutterSegment._(color: color, height: height, pillLabel: label);

  /// A segment with a document-icon marker.
  factory _GutterSegment.docIcon({required Color color, required int height}) =>
      _GutterSegment._(color: color, height: height, isDocIcon: true);

  /// A neutral segment with no marker (top-level tag rows).
  factory _GutterSegment.neutral({
    required Color color,
    required int height,
  }) =>
      _GutterSegment._(color: color, height: height);

  /// Segment color.
  final Color color;

  /// Rotated pill label; null when the segment has no pill.
  final String? pillLabel;

  /// Whether the marker is a document icon instead of a pill.
  final bool isDocIcon;

  /// Height in ROW units.
  final int height;
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
    // One rendered-set for the WHOLE tree: the same walk can never be laid
    // out twice. Paths are ORDER-SENSITIVE component walks — the same tag set
    // reached via a different order is a different (also valid) walk.
    final rendered = <String>{};
    for (final top in topLevelTags(tagsByDoc)) {
      _appendNode(rows, [top], tagsByDoc, rendered: rendered);
    }
    return Column(
      key: const ValueKey('tag-hierarchy-view'),
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

  /// Appends the node row for [components]; when expanded, its body is built
  /// via [_buildExpandedBody] and attached under the row: the gutter runs
  /// (with rotated pills spanning their row groups) live in column 1, the
  /// child rows in column 2.
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
    final body = _buildExpandedBody(
      components, pathKey, tagsByDoc,
      rendered: rendered, deferredDocs: deferredDocs, deferDocs: true,
    );
    rows.add(body);
    rows.addAll(deferredDocs);
  }

  /// Builds the EXPANSION BODY ("container") of [components]: a two-column
  /// widget whose left column is ONE gutter (a guide line in the parent
  /// tag's color, with the rotated parent pill spanning the group's rows)
  /// and whose right column holds the child rows. Nested expanded subtags
  /// contribute their OWN containers into the rows column — containers nest
  /// inside one another, shifting one gutter width per level.
  ///
  /// Deferred documents of THIS node land in [deferredDocs] (the caller
  /// places them after the container); they reserve row slots in the
  /// container's pill span so the pill stretches over them too.
  _GutterBody _buildExpandedBody(
    List<String> components,
    String pathKey,
    TagsByDoc tagsByDoc, {
    required Set<String> rendered,
    bool deferDocs = false,
    List<Widget>? deferredDocs,
  }) {
    final bodyRows = <Widget>[];

    // Direct children of the walked path, grouped by their parent tag
    // (deepest path tag first, top-level last — mirroring childTags'
    // grouping contract). Each group is ONE gutter run; its pill is the
    // group's parent tag, colored and centered over the group's rows.
    final children = childTags(components, tagsByDoc);
    final groups = <String, List<String>>{};
    for (final t in children) {
      groups.putIfAbsent(parentOf(t), () => []).add(t);
    }
    final orderedParents = <String>[];
    for (var i = components.length - 1; i >= 0; i--) {
      if (groups.containsKey(components[i])) orderedParents.add(components[i]);
    }
    if (groups.containsKey('')) orderedParents.add('');

    // One segment per row-group: parent-subtags group (parent's color +
    // pill), every other subtag group (common parent's color + pill),
    // top-level group (neutral, no marker), documents (neutral + doc icon).
    final segments = <_GutterSegment>[];

    var totalRows = 0;
    for (final parent in orderedParents) {
      final groupTags = groups[parent]!;
      final groupColor = parent.isEmpty
          ? Theme.of(context).colorScheme.outlineVariant
          : tagColorFor(parent);
      var groupHeight = 0;
      for (final t in groupTags) {
        final childComponents = [...components, t];
        final childKey = childComponents.join(_kPathSeparator);
        if (!rendered.add(childKey)) {
          bodyRows.add(SizedBox(height: _kTagRowHeight));
          groupHeight++;
          continue;
        }
        bodyRows.add(_buildTagRow(childComponents, childKey, tagsByDoc));
        groupHeight++;
        if (_expandedTagPaths.contains(childKey)) {
          // The nested container goes into the rows column of THIS
          // container: a whole new gutter+rows unit, parallel to and right
          // of this container's gutter.
          final nestedDeferred = <Widget>[];
          final nestedBody = _buildExpandedBody(
            childComponents, childKey, tagsByDoc,
            rendered: rendered, deferredDocs: nestedDeferred,
          );
          bodyRows.add(nestedBody);
          groupHeight += nestedBody.totalRows;
          deferredDocs?.addAll(nestedDeferred);
        }
      }
      segments.add(
        parent.isEmpty
            ? _GutterSegment.neutral(
                color: groupColor, height: groupHeight)
            : _GutterSegment.pill(
                color: groupColor,
                label: lastSegmentOf(parent),
                height: groupHeight,
              ),
      );
      totalRows += groupHeight;
    }

    // Directly-assigned documents of THIS path: one neutral segment with a
    // doc-icon marker. The ROOT node's docs defer to the caller.
    final comps = components.toSet();
    var docsHeight = 0;
    for (final id in docsContaining(comps, tagsByDoc)) {
      final docTags = tagsByDoc[id];
      final doc = _byId[id];
      if (doc == null || docTags == null || !docAtPath(docTags, comps)) {
        continue;
      }
      final row = _buildDocumentRow(
        doc,
        key: ValueKey('tag-doc-${doc.id}@$pathKey'),
      );
      if (deferDocs && deferredDocs != null) {
        deferredDocs.add(row);
      } else {
        bodyRows.add(row);
        docsHeight++;
      }
    }
    if (docsHeight > 0) {
      segments.add(
        _GutterSegment.docIcon(
          color: Theme.of(context).colorScheme.outlineVariant,
          height: docsHeight,
        ),
      );
      totalRows += docsHeight;
    }

    return _GutterBody(
      segments: segments,
      rows: bodyRows,
      totalRows: totalRows,
    );
  }

  /// A tag row for the path [components] (walk key [pathKey]): the LAST tag
  /// name in its own color, IDE gutter, chevron, and a count badge.
  Widget _buildTagRow(
    List<String> components,
    String pathKey,
    TagsByDoc tagsByDoc,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final expanded = _expandedTagPaths.contains(pathKey);
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
              // SizedBox(width: (depth * 20).toDouble()),
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
              // Hug the path and keep the count right after it (small gap);
              // Flexible still shrinks the path in genuinely narrow panes.
              Flexible(child: _buildColorfulPath(components)),
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

  /// A directly-assigned document row inside a container's rows column.
  Widget _buildDocumentRow(
    DocumentSummary doc, {
    Key? key,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      key: key,
      onTap: () => widget.onOpenDocument(doc),
      behavior: HitTestBehavior.opaque,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: SizedBox(
          height: _kTagRowHeight,
          child: Row(
            children: [
              Icon(
                Icons.description_outlined,
                size: 14,
                color: scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 6),
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

/// A bare count number shown right after a directory's name — no background
/// pill, just a small muted digit.
class _CountBadge extends StatelessWidget {
  const _CountBadge({super.key, required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Text(
      '$count',
      style: TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w600,
        color: scheme.onSurfaceVariant,
      ),
    );
  }
}

/// One container: column 1 is the gutter — a single vertical line split into
/// stacked [_GutterSegment]s (one per row group: parent subtags in the
/// parent's color with a rotated pill, other subtag groups in their common
/// parent's color with pills, top-level tags neutral, documents neutral with
/// a document icon) — column 2 is the child rows, including whole nested
/// containers (each nested container brings its OWN gutter column, appearing
/// one step right of the parent's).
class _GutterBody extends StatelessWidget {
  const _GutterBody({
    required this.segments,
    required this.rows,
    required this.totalRows,
  });

  /// Stacked gutter segments, top to bottom.
  final List<_GutterSegment> segments;

  /// The container's rows (child rows and nested containers).
  final List<Widget> rows;

  /// Total height of the container in ROW units.
  final int totalRows;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: totalRows * _kTagRowHeight,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: _kGutterColumnWidth.toDouble(),
            child: Column(
              children: [
                for (var i = 0; i < segments.length; i++)
                  _segment(context, i, segments[i]),
              ],
            ),
          ),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: rows,
            ),
          ),
        ],
      ),
    );
  }

  /// One gutter segment: a full-width cell with a centered vertical line and
  /// the segment's marker (pill, doc icon, or nothing) in its middle.
  Widget _segment(BuildContext context, int index, _GutterSegment seg) {
    final height = seg.height * _kTagRowHeight;
    const lineInset = _kGutterGap;
    Widget? marker;
    if (seg.pillLabel != null) {
      marker = RotatedBox(
        quarterTurns: 1,
        child: Container(
          key: ValueKey('tag-parent-pill-${seg.pillLabel}-$index'),
          padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
          decoration: BoxDecoration(
            color: seg.color,
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(
            seg.pillLabel!,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 9,
              height: 1,
            ),
          ),
        ),
      );
    } else if (seg.isDocIcon) {
      marker = Icon(
        Icons.description_outlined,
        size: 14,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      );
    }
    return SizedBox(
      height: height,
      child: Stack(
        children: [
          // Serifs: short horizontal strokes at the segment's top and
          // bottom, centered on the line.
          Positioned(
            left: (_kGutterColumnWidth / 2) - _kSerifHalfWidth,
            width: _kSerifHalfWidth * 2,
            top: lineInset - _kSerifThickness,
            child: Container(height: _kSerifThickness, color: seg.color),
          ),
          Positioned(
            left: (_kGutterColumnWidth / 2) - _kSerifHalfWidth,
            width: _kSerifHalfWidth * 2,
            bottom: lineInset - _kSerifThickness,
            child: Container(height: _kSerifThickness, color: seg.color),
          ),
          // The vertical line between the serifs.
          Positioned(
            left: (_kGutterColumnWidth - 2) / 2,
            top: lineInset,
            bottom: lineInset,
            child: Container(
              key: ValueKey('tag-guide-$index-${seg.color.toARGB32()}'),
              width: 2,
              color: seg.color,
            ),
          ),
          if (marker != null)
            Positioned.fill(
              child: IgnorePointer(
                child: Center(child: marker),
              ),
            ),
        ],
      ),
    );
  }}