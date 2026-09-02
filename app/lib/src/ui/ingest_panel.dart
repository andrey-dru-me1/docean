/// The file-ingestion surface: an optional drag-and-drop target (desktop) plus
/// an "Add files" button (all platforms), and a live progress list rendering
/// the [`IngestEvent`] stream from [`IngestService`].
///
/// Hosts can disable the boxed drop zone ([IngestPanel.showDropZone]) and
/// surface ingestion through their own full-page `DropTarget` (feeding paths
/// via [IngestPanelState.ingestPaths]) — or hide the inline button
/// ([IngestPanel.showPickerButton]) and open the picker via
/// [IngestPanelState.openPicker] — so upload affordances land exactly where the
/// page wants them. Both entry points are injectable so widget tests can
/// exercise the flow without the native `desktop_drop` / `file_picker` plugins.
library;

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../features/ingest_service.dart' show IngestEvent, IngestService;

/// Signature for opening the native file picker and returning chosen paths.
///
/// Defaults to [FilePicker.pickFiles]; tests inject a fake that returns fixed
/// paths without touching the platform channel.
typedef PathPicker = Future<List<String>> Function();

/// Opens the native multi-file picker and returns the selected local paths.
Future<List<String>> pickPathsWithFilePicker() async {
  final result = await FilePicker.pickFiles();
  return [
    for (final f in result)
      if (f.path != null && f.path!.isNotEmpty) f.path!,
  ];
}

/// The ingestion panel: drop zone + picker button + per-file progress list.
///
/// By default it renders the boxed "Drop files here" drop zone and the "Add
/// files" picker button. Hosts that want the drop zone somewhere else (e.g. a
/// full-page `DropTarget` on the Documents page) can disable each affordance
/// and drive ingestion through [IngestPanelState.openPicker] /
/// [IngestPanelState.ingestPaths].
class IngestPanel extends StatefulWidget {
  const IngestPanel({
    super.key,
    required this.ingestService,
    this.onFilesIngested,
    this.pickPaths = pickPathsWithFilePicker,
    this.showDropZone = true,
    this.showPickerButton = true,
  });

  final IngestService ingestService;

  /// Invoked after a batch finishes (success or failure) so the host screen
  /// can refresh its document list/search results.
  final VoidCallback? onFilesIngested;

  /// Injected file picker (defaults to the native `file_picker`).
  final PathPicker pickPaths;

  /// Whether to render the boxed "Drop files here" drop zone. Set to `false`
  /// when a host page supplies its own full-page `DropTarget` so drop events
  /// are never double-registered.
  final bool showDropZone;

  /// Whether to render the inline "Add files" button. Set to `false` when the
  /// page surfaces its own upload action (e.g. an app-bar icon) that calls
  /// [IngestPanelState.openPicker].
  final bool showPickerButton;

  @override
  IngestPanelState createState() => IngestPanelState();
}

/// A single file's in-flight state, updated by the event stream.
class _FileProgress {
  _FileProgress(this.fileName);

  final String fileName;
  String status = 'processing'; // processing | extracting | completed | failed
  int percent = 0;
  String? documentId;
  String? error;
}

/// The mutable state for [IngestPanel].
///
/// Exposed publicly so host pages and app-level actions (e.g. the app-bar
/// "Upload files" button) can open the file picker or feed a full-page drop
/// through the same ingestion pipeline.
class IngestPanelState extends State<IngestPanel> {
  final List<_FileProgress> _files = [];
  bool _busy = false;
  bool _dragging = false;

  /// Kick off ingestion for [paths], rendering events as they arrive.
  Future<void> _ingest(List<String> paths) async {
    if (paths.isEmpty || _busy) return;
    setState(() {
      _busy = true;
      for (final path in paths) {
        _files.add(_FileProgress(_basename(path)));
      }
    });

    try {
      final stream = widget.ingestService.ingestFiles(paths);
      await for (final event in stream) {
        if (!mounted) return;
        _apply(event);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          for (final f in _files) {
            if (f.status == 'processing' || f.status == 'extracting') {
              f.status = 'failed';
              f.error = '$e';
            }
          }
        });
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        widget.onFilesIngested?.call();
      }
    }
  }

  void _apply(IngestEvent event) {
    setState(() {
      // Find (or create) the row for this file.
      var row = _files.where((f) => f.fileName == event.fileName).firstOrNull;
      if (row == null) {
        row = _FileProgress(event.fileName);
        _files.add(row);
      }
      row.status = event.kind;
      row.percent = event.percent;
      row.documentId = event.documentId.isEmpty ? null : event.documentId;
      row.error = event.error.isEmpty ? null : event.error;
    });
  }

  String _basename(String path) {
    final normalized = path.replaceAll('\\', '/');
    final idx = normalized.lastIndexOf('/');
    return idx == -1 ? normalized : normalized.substring(idx + 1);
  }

  Future<void> openPicker() async {
    try {
      final paths = await widget.pickPaths();
      if (paths.isNotEmpty) await _ingest(paths);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not open file picker: $e')),
        );
      }
    }
  }

  /// Ingest already-resolved local [paths], e.g. from a host-provided full-page
  /// [DropTarget].
  Future<void> ingestPaths(List<String> paths) => _ingest(paths);

  void _onDrop(DropDoneDetails details) {
    final paths = [
      for (final item in details.files)
        if (item.path.isNotEmpty) item.path,
    ];
    if (paths.isNotEmpty) _ingest(paths);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.showDropZone)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: DropTarget(
              onDragEntered: (_) => setState(() => _dragging = true),
              onDragExited: (_) => setState(() => _dragging = false),
              onDragDone: _onDrop,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  vertical: 20,
                  horizontal: 16,
                ),
                decoration: BoxDecoration(
                  color: _dragging
                      ? scheme.primaryContainer
                      : scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: _dragging ? scheme.primary : scheme.outlineVariant,
                    width: _dragging ? 2 : 1,
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      _dragging ? Icons.file_download : Icons.upload_file,
                      color: _dragging ? scheme.primary : scheme.outline,
                    ),
                    const SizedBox(width: 12),
                    const Expanded(
                      child: Text(
                        'Drop files here to add them to your library',
                        textAlign: TextAlign.center,
                      ),
                    ),
                    const SizedBox(width: 12),
                    FilledButton.icon(
                      onPressed: _busy ? null : openPicker,
                      icon: const Icon(Icons.add),
                      label: const Text('Add files'),
                    ),
                  ],
                ),
              ),
            ),
          )
        else if (widget.showPickerButton)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Align(
              alignment: Alignment.centerRight,
              child: FilledButton.icon(
                onPressed: _busy ? null : openPicker,
                icon: const Icon(Icons.add),
                label: const Text('Add files'),
              ),
            ),
          ),
        if (_files.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              'Ingesting ${_files.length} file(s)',
              style: Theme.of(context).textTheme.labelMedium,
            ),
          ),
        if (_files.isNotEmpty)
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 220),
            child: ListView.separated(
              shrinkWrap: true,
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              itemCount: _files.length,
              separatorBuilder: (_, _) => const SizedBox(height: 6),
              itemBuilder: (context, i) => _FileRow(_files[i]),
            ),
          ),
      ],
    );
  }
}

class _FileRow extends StatelessWidget {
  const _FileRow(this.file);

  final _FileProgress file;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (IconData icon, Color color) = switch (file.status) {
      'completed' => (Icons.check_circle, Colors.green),
      'failed' => (Icons.error, scheme.error),
      'extracting' => (Icons.hourglass_top, scheme.primary),
      _ => (Icons.file_present, scheme.outline),
    };

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 18, color: color),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    file.fileName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ),
                Text(
                  _statusLabel(file),
                  style: Theme.of(
                    context,
                  ).textTheme.labelSmall?.copyWith(color: color),
                ),
              ],
            ),
            if (file.status == 'extracting') ...[
              const SizedBox(height: 8),
              LinearProgressIndicator(value: file.percent / 100),
            ],
            if (file.status == 'failed' && file.error != null) ...[
              const SizedBox(height: 6),
              Text(
                file.error!,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: scheme.error),
              ),
            ],
            if (file.status == 'completed' && file.documentId != null) ...[
              const SizedBox(height: 4),
              Text(
                'Document ${file.documentId}',
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: scheme.outline),
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _statusLabel(_FileProgress f) => switch (f.status) {
    'processing' => 'Processing',
    'extracting' => 'Extracting ${f.percent}%',
    'completed' => 'Done',
    'failed' => 'Failed',
    _ => f.status,
  };
}
