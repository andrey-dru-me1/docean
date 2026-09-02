import 'package:flutter/material.dart';

import '../features/document_service.dart'
    show DocumentService, ReorganizeResult;

/// Settings screen, reachable from the main shell.
///
/// Currently hosts a single bulk action: "Re-organize all documents". It runs
/// the deterministic auto-organization pipeline across every document *without*
/// an AI provider, while the Rust core honors the `title_manual` /
/// `tags_manual` flags on each document's `extra` metadata — so user's manually
/// edited titles/tags are never clobbered. The screen shows an aggregate
/// result summary (total / updated / skipped) after the pass completes, and
/// degrades gracefully when the repository is unavailable.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, required this.documentService});

  final DocumentService documentService;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _running = false;
  ReorganizeResult? _lastResult;
  Object? _error;

  Future<void> _reorganizeAll() async {
    if (_running) return;
    setState(() {
      _running = true;
      _error = null;
      _lastResult = null;
    });
    try {
      final result = await widget.documentService.reorganizeAll();
      if (!mounted) return;
      setState(() {
        _lastResult = result;
        _running = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _running = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(toolbarHeight: 44, title: const Text('Settings')),
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
                      Icon(Icons.auto_fix_high, color: scheme.primary),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          'Automatic organization',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Re-run the deterministic auto-organization pipeline over '
                    'every document. Works fully offline — no AI provider '
                    'required. Documents whose title or tags you edited by hand '
                    'are preserved (manual edits are tracked per document).',
                    style: TextStyle(height: 1.4),
                  ),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: _running ? null : _reorganizeAll,
                    icon: _running
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.auto_fix_high, size: 18),
                    label: Text(
                      _running ? 'Re-organizing…' : 'Re-organize all documents',
                    ),
                  ),
                  if (_lastResult != null) ...[
                    const SizedBox(height: 16),
                    const Divider(height: 1),
                    const SizedBox(height: 12),
                    Text(
                      'Organization complete',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    const SizedBox(height: 8),
                    _ResultRow(
                      label: 'Documents examined',
                      value: _lastResult!.total,
                    ),
                    _ResultRow(label: 'Updated', value: _lastResult!.updated),
                    _ResultRow(
                      label: 'Skipped (manual edits / no change)',
                      value: _lastResult!.skipped,
                    ),
                  ],
                  if (_error != null) ...[
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Icon(
                          Icons.error_outline,
                          color: scheme.error,
                          size: 18,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Could not re-organize: $_error',
                            style: TextStyle(color: scheme.error),
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A compact label/value row for the re-organization result summary.
class _ResultRow extends StatelessWidget {
  const _ResultRow({required this.label, required this.value});

  final String label;
  final int value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: Theme.of(context).textTheme.bodyMedium),
          Text(
            '$value',
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}
