import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:docean/src/app.dart' show DoceanApp;
import 'package:docean/src/features/document_service.dart'
    show FakeDocumentService;
import 'package:docean/src/features/library_directory.dart'
    show LibraryDirectoryService, LibrarySyncSummary;
import 'package:docean/src/features/provider_service.dart'
    show ProviderKind, ProviderService, ProviderSettings;
import 'package:docean/src/rust/api/ai.dart' show ActiveProviderInfo;
import 'package:docean/src/rust/api/health.dart' show HealthStatus;
import 'package:docean/src/ui/library_folder_dialog.dart'
    show DirectoryPicker, showLibraryFolderDialog;

/// A [LibraryDirectoryService] that records every call and returns an
/// injectable [summary] (all-zero omitted parts exercised via a non-zero
/// default: `+1 added, 2 linked`).
class _RecordingLibraryService implements LibraryDirectoryService {
  _RecordingLibraryService({this.dir});

  String? dir;
  int setCount = 0;
  int syncCount = 0;
  final List<String?> setPaths = [];
  Object? syncError;
  LibrarySyncSummary summary = const LibrarySyncSummary(
    added: 1,
    removed: 0,
    linked: 2,
    failed: 0,
  );

  @override
  Future<String?> libraryDirectory() async => dir;

  @override
  Future<void> setLibraryDirectory(String? path) async {
    setCount++;
    setPaths.add(path);
    dir = path;
  }

  @override
  Future<LibrarySyncSummary> syncLibrary() async {
    syncCount++;
    if (syncError != null) throw syncError!;
    return summary;
  }
}

/// A [_RecordingLibraryService] whose sync completes only when the injected
/// [Completer] resolves — used to assert the in-flight spinner.
class _GatedSyncService extends _RecordingLibraryService {
  _GatedSyncService({super.dir});

  final Completer<void> gate = Completer<void>();

  @override
  Future<LibrarySyncSummary> syncLibrary() async {
    syncCount++;
    await gate.future;
    return summary;
  }
}

/// Standalone host that opens the library-folder dialog on tap, so dialog
/// behavior is tested without the whole app shell.
Widget _dialogHost({
  required LibraryDirectoryService service,
  DirectoryPicker? pickDirectory,
}) {
  return MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (context) => Center(
          child: ElevatedButton(
            onPressed: () => showLibraryFolderDialog(
              context,
              service: service,
              pickDirectory: pickDirectory ?? () async => null,
            ),
            child: const Text('Open'),
          ),
        ),
      ),
    ),
  );
}

Future<void> _openDialog(
  WidgetTester tester, {
  required LibraryDirectoryService service,
  DirectoryPicker? pickDirectory,
}) async {
  await tester.pumpWidget(
    _dialogHost(service: service, pickDirectory: pickDirectory),
  );
  await tester.tap(find.text('Open'));
  await tester.pumpAndSettle();
}

HealthStatus _fakeStatus() => const HealthStatus(
  ok: true,
  engine: 'docean-core',
  engineVersion: '0.1.0',
  platform: 'test',
  timestampMs: 123,
);

/// A minimal provider double so the shell's AI probe stays offline-safe.
class _FakeProviderService implements ProviderService {
  @override
  List<ProviderSettings> listProviders() => [
    ProviderSettings(
      kind: ProviderKind.builtin,
      model: 'docean-tiny',
      enabled: true,
      models: const [],
      hasApiKey: true,
    ),
  ];

  @override
  ActiveProviderInfo activeProvider() => const ActiveProviderInfo(
    kind: 'builtin',
    model: 'docean-tiny',
    baseUrl: null,
    hasApiKey: false,
  );

  @override
  ActiveProviderInfo selectProvider(String kind, {String? model}) =>
      activeProvider();

  @override
  void saveProviderSettings(ProviderSettings settings) {}

  @override
  void setApiKey(String kind, String key) {}

  @override
  void removeApiKey(String kind) {}
}

void main() {
  group('LibraryFolderDialog', () {
    testWidgets('shows "Not set" when no directory is configured', (
      tester,
    ) async {
      final service = _RecordingLibraryService();

      await _openDialog(tester, service: service);

      expect(
        find.byKey(const ValueKey('library-folder-dialog')),
        findsOneWidget,
      );
      expect(find.text('Not set'), findsOneWidget);
      // Detach only makes sense once a directory is set.
      expect(find.byKey(const ValueKey('library-dir-detach')), findsNothing);
    });

    testWidgets('shows the configured directory when one is pre-set', (
      tester,
    ) async {
      final service = _RecordingLibraryService(dir: '/docs/inbox');

      await _openDialog(tester, service: service);

      expect(find.text('/docs/inbox'), findsOneWidget);
      expect(find.text('Not set'), findsNothing);
      expect(find.byKey(const ValueKey('library-dir-detach')), findsOneWidget);
    });

    testWidgets('sync button is disabled when no directory is set', (
      tester,
    ) async {
      final service = _RecordingLibraryService();

      await _openDialog(tester, service: service);

      final button = tester.widget<OutlinedButton>(
        find.byKey(const ValueKey('library-dir-sync')),
      );
      expect(button.onPressed, isNull);
    });

    testWidgets('choose sets the directory, syncs, and shows the summary', (
      tester,
    ) async {
      final service = _RecordingLibraryService();

      await _openDialog(
        tester,
        service: service,
        pickDirectory: () async => '/docs',
      );

      await tester.tap(find.byKey(const ValueKey('library-dir-choose')));
      await tester.pumpAndSettle();

      expect(service.dir, '/docs');
      expect(service.setPaths, ['/docs']);
      expect(service.syncCount, 1);
      // Dialog dismisses and the summary snackbar shows (zero parts omitted).
      expect(find.byKey(const ValueKey('library-folder-dialog')), findsNothing);
      expect(
        find.text('Library folder set. Synced: +1 added, 2 linked'),
        findsOneWidget,
      );
    });

    testWidgets('canceling the picker keeps the dialog open', (tester) async {
      final service = _RecordingLibraryService();

      await _openDialog(
        tester,
        service: service,
        pickDirectory: () async => null,
      );

      await tester.tap(find.byKey(const ValueKey('library-dir-choose')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('library-folder-dialog')),
        findsOneWidget,
      );
      expect(service.setCount, 0);
      expect(service.syncCount, 0);
    });

    testWidgets('sync now is enabled with a dir and shows the summary', (
      tester,
    ) async {
      final service = _RecordingLibraryService(dir: '/docs');

      await _openDialog(tester, service: service);

      final button = tester.widget<OutlinedButton>(
        find.byKey(const ValueKey('library-dir-sync')),
      );
      expect(button.onPressed, isNotNull);

      await tester.tap(find.byKey(const ValueKey('library-dir-sync')));
      await tester.pumpAndSettle();

      expect(service.syncCount, 1);
      expect(find.byKey(const ValueKey('library-folder-dialog')), findsNothing);
      expect(find.text('Library synced: +1 added, 2 linked'), findsOneWidget);
    });

    testWidgets('sync failure keeps the dialog open and shows the error', (
      tester,
    ) async {
      final service = _RecordingLibraryService(dir: '/docs')
        ..syncError = StateError('boom');

      await _openDialog(tester, service: service);

      await tester.tap(find.byKey(const ValueKey('library-dir-sync')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('library-folder-dialog')),
        findsOneWidget,
      );
      expect(find.textContaining('Sync failed:'), findsOneWidget);
    });

    testWidgets('shows an in-flight spinner inside the sync button', (
      tester,
    ) async {
      final service = _GatedSyncService(dir: '/docs');

      await _openDialog(tester, service: service);

      await tester.tap(find.byKey(const ValueKey('library-dir-sync')));
      await tester.pump();

      expect(
        find.descendant(
          of: find.byKey(const ValueKey('library-dir-sync')),
          matching: find.byType(CircularProgressIndicator),
        ),
        findsOneWidget,
      );

      service.gate.complete();
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('library-folder-dialog')), findsNothing);
    });

    testWidgets('detach clears the directory and shows a snackbar', (
      tester,
    ) async {
      final service = _RecordingLibraryService(dir: '/docs');

      await _openDialog(tester, service: service);

      await tester.tap(find.byKey(const ValueKey('library-dir-detach')));
      await tester.pumpAndSettle();

      expect(service.dir, isNull);
      expect(service.setPaths.last, isNull);
      expect(find.byKey(const ValueKey('library-folder-dialog')), findsNothing);
      expect(find.text('Library folder detached.'), findsOneWidget);
    });

    testWidgets('cancel dismisses without touching the service', (
      tester,
    ) async {
      final service = _RecordingLibraryService(dir: '/docs');

      await _openDialog(tester, service: service);

      await tester.tap(find.byKey(const ValueKey('library-dir-cancel')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('library-folder-dialog')), findsNothing);
      expect(service.setCount, 0);
      expect(service.syncCount, 0);
    });
  });

  group('MainShell library-folder integration', () {
    testWidgets('shows the library-folder icon in narrow and wide app bars', (
      tester,
    ) async {
      for (final size in [const Size(800, 600), const Size(1400, 900)]) {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        await tester.pumpWidget(
          DoceanApp(
            healthCheck: _fakeStatus,
            providerService: _FakeProviderService(),
            documentService: FakeDocumentService(),
            libraryService: _RecordingLibraryService(),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.byKey(const ValueKey('library-folder')), findsOneWidget);
        expect(find.byIcon(Icons.folder_copy_outlined), findsOneWidget);
      }
    });

    testWidgets('choose flow sets the dir, syncs, and bumps the refresh tick', (
      tester,
    ) async {
      final docs = FakeDocumentService();
      final service = _RecordingLibraryService();

      await tester.pumpWidget(
        DoceanApp(
          healthCheck: _fakeStatus,
          providerService: _FakeProviderService(),
          documentService: docs,
          libraryService: service,
          pickDirectory: () async => '/docs',
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('No documents yet'), findsOneWidget);
      final callsBefore = docs.listCount;

      await tester.tap(find.byKey(const ValueKey('library-folder')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('library-dir-choose')));
      await tester.pumpAndSettle();

      expect(service.dir, '/docs');
      expect(service.syncCount, 1);
      expect(find.byKey(const ValueKey('library-folder-dialog')), findsNothing);
      // The dialog's success bumped the tick, so the browse view re-queried.
      expect(docs.listCount, greaterThan(callsBefore));
    });

    testWidgets('manual sync from the dialog bumps the refresh tick', (
      tester,
    ) async {
      final docs = FakeDocumentService();
      // A pre-set dir also triggers the one-shot startup auto-sync.
      final service = _RecordingLibraryService(dir: '/docs');

      await tester.pumpWidget(
        DoceanApp(
          healthCheck: _fakeStatus,
          providerService: _FakeProviderService(),
          documentService: docs,
          libraryService: service,
          pickDirectory: () async => null,
        ),
      );
      await tester.pumpAndSettle();
      final callsBefore = docs.listCount;

      await tester.tap(find.byKey(const ValueKey('library-folder')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('library-dir-sync')));
      await tester.pumpAndSettle();

      expect(service.syncCount, 2); // 1 startup auto-sync + 1 manual
      expect(find.text('Library synced: +1 added, 2 linked'), findsOneWidget);
      expect(docs.listCount, greaterThan(callsBefore));
    });

    testWidgets('auto-sync fires once on startup when a dir is pre-set', (
      tester,
    ) async {
      final docs = FakeDocumentService();
      final service = _RecordingLibraryService(dir: '/pre-set');

      await tester.pumpWidget(
        DoceanApp(
          healthCheck: _fakeStatus,
          providerService: _FakeProviderService(),
          documentService: docs,
          libraryService: service,
        ),
      );
      await tester.pumpAndSettle();

      expect(service.syncCount, 1);
      // Post-sync tick bump re-queried the browse list.
      expect(docs.listCount, greaterThanOrEqualTo(2));
    });

    testWidgets('auto-sync does not fire when no dir is configured', (
      tester,
    ) async {
      final service = _RecordingLibraryService();

      await tester.pumpWidget(
        DoceanApp(
          healthCheck: _fakeStatus,
          providerService: _FakeProviderService(),
          documentService: FakeDocumentService(),
          libraryService: service,
        ),
      );
      await tester.pumpAndSettle();

      expect(service.syncCount, 0);
    });
  });
}
