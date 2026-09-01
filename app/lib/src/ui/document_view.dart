import 'package:flutter/material.dart';

/// A compact summary of a document enough to open it in a detail view.
///
/// Shared by the search results and the chat citations so both can hand a
/// document to [DocumentDetailView].
class DocumentSummary {
  const DocumentSummary({
    required this.id,
    required this.title,
    this.snippet,
    this.tags = const [],
    this.paths = const [],
  });

  final String id;
  final String title;
  final String? snippet;
  final List<String> tags;
  final List<String> paths;
}

/// A full-screen detail view for a document opened from a search result or a
/// chat citation.
///
/// This is intentionally self-contained: it renders the metadata and excerpt
/// already available to the search/chat facade. The main document UI task owns
/// the repository-backed content reader; that can be layered in behind
/// [DocumentSummary] later without changing this screen's contract.
class DocumentDetailView extends StatelessWidget {
  const DocumentDetailView({super.key, required this.document, this.onBack});

  final DocumentSummary document;
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        leading: onBack == null
            ? null
            : IconButton(icon: const Icon(Icons.arrow_back), onPressed: onBack),
        title: const Text('Document'),
        actions: [
          IconButton(
            tooltip: 'Close',
            icon: const Icon(Icons.close),
            onPressed: onBack,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.description_outlined,
                        size: 40,
                        color: scheme.primary,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          document.title,
                          style: Theme.of(context).textTheme.headlineSmall,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'ID: ${document.id}',
                    style: Theme.of(
                      context,
                    ).textTheme.bodySmall?.copyWith(color: scheme.outline),
                  ),
                  if (document.tags.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        for (final tag in document.tags)
                          Chip(
                            avatar: const Icon(Icons.label_outline, size: 14),
                            label: Text(tag),
                          ),
                      ],
                    ),
                  ],
                  if (document.paths.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        for (final path in document.paths)
                          Chip(
                            avatar: const Icon(Icons.folder_outlined, size: 14),
                            label: Text(path),
                          ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),
          if (document.snippet != null && document.snippet!.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text(
              'Content preview',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  document.snippet!,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
            ),
          ],
          const SizedBox(height: 48),
        ],
      ),
    );
  }
}

/// A reusable import so screens can navigate to a [DocumentDetailView].
Widget documentDetailViewFor(DocumentSummary doc, {VoidCallback? onBack}) =>
    DocumentDetailView(document: doc, onBack: onBack);
