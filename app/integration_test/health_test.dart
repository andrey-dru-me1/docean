import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:docer/src/app.dart';
import 'package:docer/src/rust/api/auto_org.dart'
    show autoOrgDefaultConfig, autoOrgOrganize, autoOrgReorganizeOne;
import 'package:docer/src/rust/api/search.dart'
    show SearchMode, SearchRequestDto, searchIndexDocument, searchQuery;
import 'package:docer/src/rust/api/storage.dart' show openRepository;
import 'package:docer/src/rust/domain.dart' show Document, NodeKind;
import 'package:docer/src/rust/frb_generated.dart';

/// Real end-to-end tests: load the native `docer-core` library and exercise the
/// search + chat + provider UI through the bridge.
///
/// Run on a desktop target, e.g. `flutter test integration_test -d macos`.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async => await RustLib.init());

  testWidgets('shell shows the engine status chip', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const DocerApp());
    await tester.pumpAndSettle();

    expect(find.textContaining('Engine OK'), findsOneWidget);
    // The navigation destinations are present.
    expect(find.text('Search'), findsWidgets);
    expect(find.text('Chat'), findsWidgets);
  });

  testWidgets('search bridge indexes text and returns highlights', (
    WidgetTester tester,
  ) async {
    searchIndexDocument(documentId: 'it-doc', text: 'Integration test fox');
    final hits = searchQuery(
      req: SearchRequestDto(
        text: 'fox',
        mode: SearchMode.exact,
        tags: const [],
        paths: const [],
      ),
    );
    expect(hits, isNotEmpty);
    expect(hits.first.documentId, 'it-doc');
    expect(hits.first.snippet, contains('fox'));
  });

  testWidgets(
    'auto-org bridge reuses one repository handle across sequential calls',
    (tester) async {
      final root =
          '${Directory.systemTemp.path}/docer-it-${DateTime.now().microsecondsSinceEpoch}';
      final repo = await openRepository(root: root);
      final text =
          'quarterly invoice for office supplies from acme corporation';

      await repo.put(
        doc: Document(
          id: 'it-org-1',
          parentId: null,
          kind: NodeKind.document,
          title: 'Untagged draft',
          mimeType: 'text/plain',
          sizeBytes: BigInt.from(text.length),
          checksumSha256: '',
          tags: const ['stale'],
          createdAtMs: 1,
          updatedAtMs: 1,
          extra: const {},
        ),
        bytes: utf8.encode(text),
      );
      await repo.putContent(documentId: 'it-org-1', text: text, source: 'test');

      final config = autoOrgDefaultConfig();
      // First call through the shared handle.
      final first = autoOrgReorganizeOne(
        repo: repo,
        documentId: 'it-org-1',
        config: config,
      );
      expect(
        first.tags.isNotEmpty || first.suggestedTitle != null,
        isTrue,
        reason: 'first reorganize_one should produce a suggestion',
      );

      // A second call through the SAME (un-cloned) handle. Before the fix this
      // reused a disposed RustArc and threw DroppableDisposedException.
      final second = autoOrgReorganizeOne(
        repo: repo,
        documentId: 'it-org-1',
        config: config,
      );
      expect(
        second.tags,
        first.tags,
        reason: 'deterministic pass yields the same suggestions twice',
      );

      // A different auto-org entry point on the same handle also works.
      final plan = autoOrgOrganize(
        repo: repo,
        documentId: 'it-org-1',
        config: config,
      );
      expect(plan.documentId, 'it-org-1');

      // The handle is still fully usable for reads afterwards.
      final doc = await repo.get_(id: 'it-org-1');
      expect(doc.id, 'it-org-1');

      // Clean up the temp repository.
      try {
        await Directory(root).delete(recursive: true);
      } on FileSystemException {
        // Best-effort cleanup only.
      }
    },
  );
}
