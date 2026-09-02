/// Wraps the Documents browse page with the library's file-upload surface:
///
///  * the **whole page** is a drag-and-drop target for files,
///  * a compact ingest progress list renders [`IngestEvent`]s from
///    [IngestService],
///  * the shared [IngestPanel] state is reachable through [ingestPanelKey] so
///    an app-bar "Upload files" action can open the file picker from anywhere.
///
/// Drag-and-drop intentionally lives *here* (the Documents page) and not on any
/// other tab, so the Search surface stays purely a search surface.
library;

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';

import '../features/ingest_service.dart' show IngestService;
import 'ingest_panel.dart'
    show IngestPanel, IngestPanelState, PathPicker, pickPathsWithFilePicker;

/// The Documents page plus its upload chrome (whole-page drop target, progress
/// list) around a [child] browse surface.
class DocumentsUploadPage extends StatefulWidget {
  const DocumentsUploadPage({
    super.key,
    required this.child,
    required this.ingestService,
    required this.ingestPanelKey,
    this.pickPaths = pickPathsWithFilePicker,
    this.onFilesIngested,
    this.enabled = true,
  });

  /// The Documents browse surface (the page underneath the upload chrome).
  final Widget child;

  final IngestService ingestService;

  /// Exposes the shared [IngestPanelState] so app-bar upload actions can open
  /// the picker and the full-page drop can feed dropped paths.
  final GlobalKey<IngestPanelState> ingestPanelKey;

  final PathPicker pickPaths;

  /// Invoked after a batch finishes so the owning shell can refresh the
  /// Documents browse list.
  final VoidCallback? onFilesIngested;

  /// Whether the full-page drop target is active. The shell disables it while
  /// the user is on another tab so an offstage Documents page never catches
  /// drops meant for the visible tab.
  final bool enabled;

  @override
  State<DocumentsUploadPage> createState() => _DocumentsUploadPageState();
}

class _DocumentsUploadPageState extends State<DocumentsUploadPage> {
  bool _dragging = false;

  void _onDrop(DropDoneDetails details) {
    final paths = [
      for (final item in details.files)
        if (item.path.isNotEmpty) item.path,
    ];
    if (paths.isNotEmpty) {
      widget.ingestPanelKey.currentState?.ingestPaths(paths);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Stack(
      fit: StackFit.expand,
      children: [
        DropTarget(
          enable: widget.enabled,
          onDragEntered: (_) => setState(() => _dragging = true),
          onDragExited: (_) => setState(() => _dragging = false),
          onDragDone: _onDrop,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Compact ingest progress: no boxed drop zone (the whole page is
              // the target) and no inline button (the app-bar icon opens the
              // picker). Zero-height until a batch starts streaming events.
              IngestPanel(
                key: widget.ingestPanelKey,
                ingestService: widget.ingestService,
                pickPaths: widget.pickPaths,
                onFilesIngested: widget.onFilesIngested,
                showDropZone: false,
                showPickerButton: false,
              ),
              Expanded(child: widget.child),
            ],
          ),
        ),
        if (_dragging)
          Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: scheme.primaryContainer.withValues(alpha: 0.4),
                  border: Border.all(color: scheme.primary, width: 2),
                ),
                child: Center(
                  child: Card(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 24,
                        vertical: 12,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.file_open, color: scheme.primary),
                          const SizedBox(width: 10),
                          const Text('Drop files to add them to your library'),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
