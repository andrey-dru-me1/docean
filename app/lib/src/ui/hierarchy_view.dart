import 'package:flutter/material.dart';

import 'document_view.dart' show DocumentSummary;
import 'widgets.dart' show TagChip;

/// A parsed `key:value` property tag.  Scope tags (`scope:<name>`) and plain
/// tags without a valid key/value shape are dropped by [docProperties].
class DocProperty {
  const DocProperty({required this.key, required this.value});

  final String key;
  final String value;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DocProperty && other.key == key && other.value == value;

  @override
  int get hashCode => Object.hash(key, value);
}

/// Property tag shape: lowercase alphanumeric key (with `-`/`_`) followed by a
/// `:` and a non-empty value that contains no further `:`.
final _propRe = RegExp(r'^[a-z0-9_-]+:[^:]+$');

/// Parses every property-shaped tag into [DocProperty]s.  Invalid tags and
/// scope tags are ignored (scope is handled separately by [docScopes]).
List<DocProperty> docProperties(Iterable<String> tags) => [
  for (final tag in tags)
    if (_propRe.hasMatch(tag) && !tag.startsWith('scope:'))
      DocProperty(
        key: tag.split(':').first,
        value: tag.substring(tag.indexOf(':') + 1),
      ),
];

/// Returns every scope name carried by the document via its `scope:<name>`
/// tags.  A document may carry multiple scope tags (e.g. an article in
/// `teaching/diploma` carries both `scope:teaching` and `scope:diploma`
/// because the core auto-stamps ancestor scopes), and may belong to two
/// unrelated chains at once.
List<String> docScopes(Iterable<String> tags) => [
  for (final tag in tags)
    if (tag.startsWith('scope:')) tag.substring('scope:'.length),
];

/// A scope in the co-occurrence-derived scope tree.
///
/// [name] is the plain scope name (the value of the `scope:` tag), [label] is
/// the indented display label for the picker ("parent ▸ child"), and
/// [children] holds the deeper scopes nested under this one.
class ScopeNode {
  const ScopeNode({
    required this.name,
    required this.label,
    required this.children,
  });

  final String name;
  final String label;
  final List<ScopeNode> children;
}

/// Builds the scope tree from the current document set.
///
/// Heuristic (derived deterministically from the docs' own scope tags only —
/// parents cannot be known from tag names alone):
///
/// * Every unordered pair of scopes co-occurring on the same document is a
///   candidate parent-child edge.
/// * Direction: the scope that appears on MORE documents in the set is the
///   parent (a broader ancestor is stamped on a superset of documents); ties
///   break lexically (smaller name is the parent).
/// * A scope keeps the first parent assigned to it (conflicting co-occurrences
///   never re-parent it), so the result is always a tree.
/// * Roots are scopes never assigned a parent; children are sorted by name.
List<ScopeNode> buildScopeTree(Iterable<DocumentSummary> documents) {
  final docs = documents.toList();
  var counts = <String, int>{};
  for (final doc in docs) {
    for (final scope in docScopes(doc.tags).toSet()) {
      counts[scope] = (counts[scope] ?? 0) + 1;
    }
  }
  final scopes = counts.keys.toList()..sort();
  final parentOf = <String, String?>{for (final s in scopes) s: null};
  final childrenOf = <String, List<String>>{
    for (final s in scopes) s: <String>[],
  };

  for (final doc in docs) {
    final docScopesList = docScopes(doc.tags).toSet().toList()..sort();
    for (var i = 0; i < docScopesList.length; i++) {
      for (var j = i + 1; j < docScopesList.length; j++) {
        final (parent, child) = _decideParent(
          docScopesList[i],
          docScopesList[j],
          counts,
        );
        if (parentOf[child] == null) parentOf[child] = parent;
      }
    }
  }
  for (final entry in parentOf.entries) {
    final parent = entry.value;
    if (parent != null) childrenOf[parent]!.add(entry.key);
  }
  for (final children in childrenOf.values) {
    children.sort();
  }

  ScopeNode nodeFor(String name, String prefix) {
    final label = prefix.isEmpty ? name : '$prefix ▸ $name';
    return ScopeNode(
      name: name,
      label: label,
      children: [
        for (final child in childrenOf[name]!) nodeFor(child, label),
      ],
    );
  }

  final roots = scopes.where((s) => parentOf[s] == null);
  return [for (final root in roots) nodeFor(root, '')];
}

/// Decides which of two co-occurring scopes is the parent: the one present on
/// more documents (broader scope), with lexical tiebreak.
(String, String) _decideParent(
  String a,
  String b,
  Map<String, int> counts,
) {
  final ca = counts[a]!;
  final cb = counts[b]!;
  if (ca != cb) return ca > cb ? (a, b) : (b, a);
  return a.compareTo(b) < 0 ? (a, b) : (b, a);
}

/// A node in the in-memory grouping tree: the property value it groups by
/// ([value], null at the root), the documents directly attached at this level,
/// and its child groups for the remaining order keys.
class _GroupNode {
  _GroupNode({this.value});

  String? value;
  final List<DocumentSummary> docs = [];
  final List<_GroupNode> children = [];
}

/// Groups [docs] level by level following [order].  A document missing a key
/// falls into a `(none)` bucket at that level.
List<_GroupNode> _buildTree(List<DocumentSummary> docs, List<String> order) {
  if (docs.isEmpty) return [];
  if (order.isEmpty) {
    final leaf = _GroupNode();
    leaf.docs.addAll(docs);
    return [leaf];
  }

  final key = order.first;
  final grouped = <String, List<DocumentSummary>>{};
  for (final doc in docs) {
    final match = docProperties(doc.tags).where((p) => p.key == key);
    final value = match.isEmpty ? '(none)' : match.first.value;
    grouped.putIfAbsent(value, () => []).add(doc);
  }

  final rest = order.sublist(1);
  final nodes = <_GroupNode>[];
  for (final value in grouped.keys.toList()..sort()) {
    final node = _GroupNode(value: value);
    node.children.addAll(_buildTree(grouped[value]!, rest));
    nodes.add(node);
  }
  return nodes;
}

/// Collapses single-child chains: a group with exactly one child group and no
/// direct documents merges with that child, rendering as ONE tile labeled
/// `v1 / v2 / ...`.
List<_GroupNode> _collapseChains(List<_GroupNode> nodes) {
  final result = <_GroupNode>[];
  for (final node in nodes) {
    // Collapse each child's subtree first; replacing (not appending) keeps the
    // tree free of duplicated nodes.
    final collapsedChildren = _collapseChains(node.children);
    node.children
      ..clear()
      ..addAll(collapsedChildren);
    if (node.docs.isEmpty &&
        node.children.length == 1 &&
        node.value != null) {
      final child = node.children.first;
      final merged = _GroupNode(
        value: child.value != null
            ? '${node.value} / ${child.value}'
            : node.value,
      )
        ..docs.addAll(child.docs)
        ..children.addAll(child.children);
      result.add(merged);
    } else {
      result.add(node);
    }
  }
  return result;
}

/// Assigns a stable pre-order index to every group node, used for the
/// `hier-group-<i>` tile keys.
class _GroupIndexer {
  int _next = 0;
  int take() => _next++;
}

/// The hierarchical (tree) view of filtered documents.
///
/// Groups the currently filtered documents into a tree by property values in
/// the order given by [order].  A scope dropdown narrows the tree to one
/// scope's documents; the order editor opens a reorder sheet owned by the
/// parent ([onPickOrder]).
class HierarchyView extends StatelessWidget {
  const HierarchyView({
    required this.documents,
    required this.scope,
    required this.order,
    required this.onOpenDocument,
    required this.onPickScope,
    required this.onPickOrder,
    this.selectionMode = false,
    this.selectedIds = const {},
    this.onToggleSelected,
    super.key,
  });

  /// The currently filtered documents (before scope narrowing).
  final List<DocumentSummary> documents;

  /// The selected scope name, or null for "(no scope)".  Selecting an
  /// ancestor scope includes its descendant documents (they carry the
  /// ancestor's `scope:` tag too).
  final String? scope;

  /// The property keys to group by, in order.
  final List<String> order;

  final void Function(DocumentSummary) onOpenDocument;

  /// Called when the scope dropdown changes; null selects "(no scope)".
  final ValueChanged<String?> onPickScope;

  /// Opens the order editor bottom sheet (owned by the parent).
  final VoidCallback onPickOrder;

  /// When true, leaf rows get a checkbox and taps toggle selection instead of
  /// opening the document.
  final bool selectionMode;

  final Set<String> selectedIds;

  final ValueChanged<String>? onToggleSelected;

  @override
  Widget build(BuildContext context) {
    return _HierarchyTree(
      documents: documents,
      scope: scope,
      order: order,
      onOpenDocument: onOpenDocument,
      onPickScope: onPickScope,
      onPickOrder: onPickOrder,
      selectionMode: selectionMode,
      selectedIds: selectedIds,
      onToggleSelected: onToggleSelected,
    );
  }
}

class _HierarchyTree extends StatefulWidget {
  const _HierarchyTree({
    required this.documents,
    required this.scope,
    required this.order,
    required this.onOpenDocument,
    required this.onPickScope,
    required this.onPickOrder,
    required this.selectionMode,
    required this.selectedIds,
    required this.onToggleSelected,
  });

  final List<DocumentSummary> documents;
  final String? scope;
  final List<String> order;
  final void Function(DocumentSummary) onOpenDocument;
  final ValueChanged<String?> onPickScope;
  final VoidCallback onPickOrder;
  final bool selectionMode;
  final Set<String> selectedIds;
  final ValueChanged<String>? onToggleSelected;

  @override
  State<_HierarchyTree> createState() => _HierarchyTreeState();
}

class _HierarchyTreeState extends State<_HierarchyTree> {
  bool _allExpanded = false;

  /// Scope tree flattened parents-before-children for the picker.
  List<ScopeNode> get _scopeNodes {
    final nodes = <ScopeNode>[];
    void visit(List<ScopeNode> list) {
      for (final node in list) {
        nodes.add(node);
        visit(node.children);
      }
    }

    visit(buildScopeTree(widget.documents));
    return nodes;
  }

  /// Documents belonging to the selected scope.  An ancestor scope matches
  /// every document carrying its `scope:` tag (descendants included); null
  /// selects only documents carrying no scope tag at all.
  List<DocumentSummary> get _scopedDocs {
    return widget.documents.where((d) {
      final scopes = docScopes(d.tags);
      if (widget.scope == null) return scopes.isEmpty;
      return scopes.contains(widget.scope);
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.documents.isEmpty) {
      return const Center(child: Text('No documents'));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildBar(context),
        const Divider(height: 1),
        Expanded(child: _buildBody(_scopedDocs)),
      ],
    );
  }

  Widget _buildBar(BuildContext context) {
    final scopeNodes = _scopeNodes;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
      child: Row(
        children: [
          DropdownButton<String?>(
            key: const ValueKey('hier-scope'),
            value: widget.scope,
            hint: const Text('(no scope)'),
            isDense: true,
            items: [
              const DropdownMenuItem<String?>(
                value: null,
                child: Text('(no scope)'),
              ),
              for (final node in scopeNodes)
                DropdownMenuItem<String?>(
                  key: ValueKey('hier-scope-item-${node.name}'),
                  value: node.name,
                  child: Text(node.label),
                ),
            ],
            onChanged: widget.onPickScope,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              widget.order.isEmpty
                  ? 'No grouping properties'
                  : 'Group by: ${widget.order.join(' › ')}',
              style: Theme.of(context).textTheme.bodySmall,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          IconButton(
            key: const ValueKey('hier-edit-order'),
            tooltip: 'Edit grouping order',
            onPressed: widget.onPickOrder,
            icon: const Icon(Icons.reorder, size: 20),
          ),
          IconButton(
            key: const ValueKey('hier-toggle-all'),
            tooltip: _allExpanded ? 'Collapse all' : 'Expand all',
            onPressed: () => setState(() => _allExpanded = !_allExpanded),
            icon: Icon(
              _allExpanded ? Icons.unfold_less : Icons.unfold_more,
              size: 20,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBody(List<DocumentSummary> scopedDocs) {
    if (scopedDocs.isEmpty) {
      return const Center(child: Text('No documents in this scope'));
    }

    final tree = _collapseChains(_buildTree(scopedDocs, widget.order));
    // A flat root (no order keys, or everything in one "(none)" bucket) shows
    // the documents directly instead of a single redundant tile.
    if (tree.length == 1 &&
        tree.first.value == null &&
        tree.first.children.isEmpty) {
      return _buildDocList(tree.first.docs);
    }

    // Remount the whole tree when the expand-all toggle flips so every
    // ExpansionTile picks up the new `initiallyExpanded`.
    final indexer = _GroupIndexer();
    return KeyedSubtree(
      key: ValueKey('hier-expansion-remount-$_allExpanded'),
      child: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        children: [
          for (final node in tree) _buildGroup(node, indexer),
        ],
      ),
    );
  }

  Widget _buildGroup(_GroupNode node, _GroupIndexer indexer) {
    final index = indexer.take();
    final children = <Widget>[
      if (node.docs.isNotEmpty)
        for (final doc in node.docs) _buildDocRow(doc),
      if (node.children.isNotEmpty)
        for (final child in node.children) _buildGroup(child, indexer),
    ];
    return ExpansionTile(
      key: ValueKey('hier-group-$index'),
      initiallyExpanded: _allExpanded,
      title: Text(node.value ?? '(none)'),
      children: children,
    );
  }

  Widget _buildDocList(List<DocumentSummary> docs) {
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      children: [for (final doc in docs) _buildDocRow(doc)],
    );
  }

  Widget _buildDocRow(DocumentSummary doc) {
    final props = docProperties(doc.tags);
    return ListTile(
      key: ValueKey('hier-doc-${doc.id}'),
      onTap: widget.selectionMode
          ? () => widget.onToggleSelected?.call(doc.id)
          : () => widget.onOpenDocument(doc),
      title: Text(
        doc.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: props.isEmpty
          ? null
          : Wrap(
              spacing: 4,
              runSpacing: 4,
              children: [
                for (final prop in props)
                  TagChip(label: '${prop.key}:${prop.value}'),
              ],
            ),
      trailing: widget.selectionMode
          ? Checkbox(
              key: ValueKey('hier-check-${doc.id}'),
              value: widget.selectedIds.contains(doc.id),
              onChanged: (_) => widget.onToggleSelected?.call(doc.id),
            )
          : null,
    );
  }
}