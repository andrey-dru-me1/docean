import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:docean/src/p2p_sync_screen.dart';
import 'package:docean/src/features/sync.dart' as sync;
import 'package:docean/src/rust/api/p2p.dart' show PeerInfo;
import 'package:docean/src/rust/api/sync.dart'
    show SyncConflictDto, SyncConflictKindDto;
import 'package:docean/src/rust/net/models.dart' as net;

void main() {
  // Fixture: a single discovered (but disconnected) peer and one pending conflict.
  final peers = [
    const PeerInfo(
      id: '12D3KooWPeer',
      addresses: ['/ip4/127.0.0.1/udp/9090/quic-v1'],
      state: net.ConnectionState.disconnected,
    ),
  ];
  final conflicts = [
    SyncConflictDto(
      documentId: 'doc-c',
      kind: SyncConflictKindDto.contentDiverged,
      localChecksum: 'hash-a',
      remoteChecksum: 'hash-b',
      localUpdatedAtMs: 1000,
      remoteUpdatedAtMs: 2000,
      forkedDocumentId: 'doc-c.conflict.hash-b',
      winner: 'fork',
    ),
  ];

  P2pSyncScreen buildScreen() {
    return P2pSyncScreen(
      localPeerId: () => '12D3KooWLocal',
      listPeers: () => peers,
      connectPeer: (_, _) {},
      p2pEvents: () => const Stream.empty(),
      syncStart: () {},
      syncPeers: () => ['peer-b'],
      syncConnect: (_) {},
      syncPush: (_) {},
      syncPull: () => [
        const sync.SyncResolutionDto(
          kind: 'forked',
          documentId: 'doc-c.conflict.hash-b',
        ),
      ],
      syncConflicts: () => conflicts,
      syncEvents: () => const Stream.empty(),
    );
  }

  testWidgets('renders local id, peers, sync peers, and conflicts', (
    tester,
  ) async {
    await tester.pumpWidget(MaterialApp(home: buildScreen()));
    await tester.pump();

    expect(find.textContaining('12D3KooWLocal'), findsOneWidget);
    expect(find.text('12D3KooWPeer'), findsOneWidget);
    expect(find.textContaining('peer-b'), findsOneWidget);
    // The conflict document id appears in the conflicts section (scroll to it).
    await tester.scrollUntilVisible(
      find.text('doc-c'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('doc-c'), findsOneWidget);
    expect(find.textContaining('fork'), findsWidgets);
  });

  testWidgets('pull action reports a resolution to the log', (tester) async {
    await tester.pumpWidget(MaterialApp(home: buildScreen()));
    await tester.pump();

    await tester.scrollUntilVisible(
      find.text('Pull (reconcile)'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Pull (reconcile)'));
    await tester.pump();

    expect(find.textContaining('pull -> 1 resolution(s)'), findsOneWidget);
  });
}
