library;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../features/library_directory.dart'
    show LibraryDirectoryService, LibrarySyncSummary;

/// Signature for opening the native directory picker and returning the chosen
/// path (`null` when the user cancels).
///
/// Defaults to [FilePicker.getDirectoryPath]; tests inject a fake that returns
/// a fixed path without touching the platform channel.
typedef DirectoryPicker = Future<String?> Function();

/// Opens the native directory picker and returns the selected folder path.
Future<String?> pickDirectoryWithFilePicker() => FilePicker.getDirectoryPath();

/// Shows the library-folder dialog. Resolves `true` when the user set, synced,
/// or detached the folder (the host should refresh its document list); `false`
/// on cancel.
Future<bool?> showLibraryFolderDialog(
  BuildContext context, {
  required LibraryDirectoryService service,
  DirectoryPicker? pickDirectory,
}) {
  return showDialog<bool>(
    context: context,
    builder: (_) => LibraryFolderDialog(
      service: service,
      pickDirectory: pickDirectory ?? pickDirectoryWithFilePicker,
    ),
  );
}

class LibraryFolderDialog extends StatefulWidget {
  const LibraryFolderDialog({
    super.key,
    required this.service,
    required this.pickDirectory,
  });

  final LibraryDirectoryService service;
  final DirectoryPicker pickDirectory;

  @override
  State<LibraryFolderDialog> createState() => _LibraryFolderDialogState();
}

class _LibraryFolderDialogState extends State<LibraryFolderDialog> {
  String? _dir;
  bool _syncing = false;

  @override
  void initState() {
    super.initState();
    _loadDir();
  }

  Future<void> _loadDir() async {
    final dir = await widget.service.libraryDirectory();
    if (mounted) setState(() => _dir = dir);
  }

  void _showSnack(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  Future<void> _chooseFolder() async {
    final picked = await widget.pickDirectory();
    if (picked == null || picked.isEmpty) return;
    setState(() => _syncing = true);
    try {
      await widget.service.setLibraryDirectory(picked);
      final summary = await widget.service.syncLibrary();
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      Navigator.of(context).pop(true);
      messenger.showSnackBar(
        SnackBar(
          content: Text('Library folder set. Synced: ${_formatSync(summary)}'),
        ),
      );
    } catch (e) {
      if (mounted) {
        setState(() => _syncing = false);
        _showSnack('Could not set library folder: $e');
      }
    }
  }

  Future<void> _syncNow() async {
    setState(() => _syncing = true);
    try {
      final summary = await widget.service.syncLibrary();
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      Navigator.of(context).pop(true);
      messenger.showSnackBar(
        SnackBar(content: Text('Library synced: ${_formatSync(summary)}')),
      );
    } catch (e) {
      if (mounted) {
        setState(() => _syncing = false);
        _showSnack('Sync failed: $e');
      }
    }
  }

  Future<void> _detach() async {
    await widget.service.setLibraryDirectory(null);
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    Navigator.of(context).pop(true);
    messenger.showSnackBar(
      const SnackBar(content: Text('Library folder detached.')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final set = _dir != null && _dir!.isNotEmpty;
    return AlertDialog(
      key: const ValueKey('library-folder-dialog'),
      title: const Text('Library folder'),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Folder', style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 4),
            Text(
              _dir ?? 'Not set',
              key: const ValueKey('library-dir-current'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              key: const ValueKey('library-dir-choose'),
              onPressed: _syncing ? null : _chooseFolder,
              icon: const Icon(Icons.folder_open),
              label: const Text('Choose folder…'),
            ),
            const SizedBox(height: 8),
            OutlinedButton(
              key: const ValueKey('library-dir-sync'),
              onPressed: (set && !_syncing) ? _syncNow : null,
              child: _syncing
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Sync now'),
            ),
          ],
        ),
      ),
      actions: [
        if (set)
          TextButton(
            key: const ValueKey('library-dir-detach'),
            onPressed: _syncing ? null : _detach,
            child: const Text('Detach folder'),
          ),
        TextButton(
          key: const ValueKey('library-dir-cancel'),
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}

/// Renders a [LibrarySyncSummary] as "+N added, -M removed, …", omitting any
/// zero-count part so an all-zero result reads "no changes".
String _formatSync(LibrarySyncSummary summary) {
  final parts = <String>[
    if (summary.added > 0) '+${summary.added} added',
    if (summary.removed > 0) '-${summary.removed} removed',
    if (summary.linked > 0) '${summary.linked} linked',
    if (summary.failed > 0) '${summary.failed} failed',
  ];
  return parts.isEmpty ? 'no changes' : parts.join(', ');
}