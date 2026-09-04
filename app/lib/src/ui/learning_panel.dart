import 'package:flutter/material.dart';

import '../features/document_service.dart' show DocumentService;
import '../features/learning_prefs.dart'
    show setSuggestionLearningMode, suggestionLearningMode;
import '../rust/auto_org/feedback.dart' show LearningMode;

/// The "Suggestion learning" settings block on the Providers screen.
///
/// Lets the user choose between learning `Off` (no feedback recorded, no
/// re-ranking) and `Basic` (on-device per-term preference model, default), and
/// wipe all learned feedback. All data stays on-device; nothing ever leaves the
/// app.
class LearningPanel extends StatefulWidget {
  const LearningPanel({super.key, required this.documentService});

  final DocumentService documentService;

  @override
  State<LearningPanel> createState() => _LearningPanelState();
}

class _LearningPanelState extends State<LearningPanel> {
  late LearningMode _mode = suggestionLearningMode();
  bool _resetting = false;

  Future<void> _reset() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Reset learning?'),
        content: const Text(
          'This deletes everything the suggestion model has learned from '
          'your choices. Your documents and tags are not affected.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const ValueKey('confirm-reset-learning'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Reset'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _resetting = true);
    try {
      await widget.documentService.resetSuggestionFeedback();
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Learning data reset')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not reset learning: $e')));
    } finally {
      if (mounted) setState(() => _resetting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.auto_awesome, size: 20, color: scheme.primary),
                const SizedBox(width: 8),
                Text(
                  'Suggestion learning',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'When you keep or switch an AI-suggested title/tag, the app learns '
              'your preference on-device and ranks future suggestions to match. '
              'No data leaves this device.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            SegmentedButton<LearningMode>(
              key: const ValueKey('learning-mode'),
              segments: const [
                ButtonSegment(
                  value: LearningMode.off,
                  label: Text('Off'),
                  icon: Icon(Icons.block, size: 16),
                ),
                ButtonSegment(
                  value: LearningMode.basic,
                  label: Text('Basic'),
                  icon: Icon(Icons.auto_awesome, size: 16),
                ),
              ],
              selected: {_mode},
              onSelectionChanged: (selection) {
                setState(() => _mode = selection.first);
                setSuggestionLearningMode(_mode);
              },
            ),
            const SizedBox(height: 4),
            Text(
              'Basic: learn from my choices · Off: no feedback recorded',
              style: Theme.of(
                context,
              ).textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              key: const ValueKey('reset-learning'),
              onPressed: _resetting ? null : _reset,
              icon: _resetting
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.delete_outline, size: 16),
              label: const Text('Reset learning data'),
            ),
          ],
        ),
      ),
    );
  }
}
