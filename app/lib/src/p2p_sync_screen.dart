import 'package:flutter/material.dart';

import 'features/p2p.dart' as p2p;
import 'features/sync.dart' as sync;

/// A functional, bridge-backed UI surface for the P2P + sync features.
///
/// It wires the Flutter UI to the Rust core through the existing facades
/// (`features/p2p.dart` and `features/sync.dart`):
///
/// * device discovery — the local peer id plus the current peer list (mDNS);
/// * connection — dial a peer by id + multiaddr;
/// * send / receive — `sync.push` replicates a document, `sync.pull` pulls and
///   reconciles remote changes;
/// * conflict resolution — pending conflicts are listed, and sync events
///   (including near-duplicate "related version" proposals) stream into a log.
///
/// The bridge functions are injectable so widget tests can exercise the screen
/// without loading the native library.
class P2pSyncScreen extends StatefulWidget {
  const P2pSyncScreen({
    super.key,
    this.localPeerId = p2p.localPeerId,
    this.listPeers = p2p.listPeers,
    this.connectPeer = p2p.connect,
    this.p2pEvents = p2p.events,
    this.syncStart = sync.start,
    this.syncPeers = sync.peers,
    this.syncConnect = sync.connect,
    this.syncPush = sync.push,
    this.syncPull = sync.pull,
    this.syncConflicts = sync.conflicts,
    this.syncEvents = sync.events,
  });

  final String Function() localPeerId;
  final List<p2p.PeerInfo> Function() listPeers;
  final void Function(String peerId, String addr) connectPeer;
  final Stream<p2p.PeerEvent> Function() p2pEvents;

  final void Function() syncStart;
  final List<String> Function() syncPeers;
  final void Function(String peerId) syncConnect;
  final void Function(String documentId) syncPush;
  final List<sync.SyncResolutionDto> Function() syncPull;
  final List<sync.SyncConflictDto> Function() syncConflicts;
  final Stream<sync.SyncEventDto> Function() syncEvents;

  @override
  State<P2pSyncScreen> createState() => _P2pSyncScreenState();
}

class _P2pSyncScreenState extends State<P2pSyncScreen> {
  final _peerIdController = TextEditingController();
  final _addrController = TextEditingController();
  final _connectController = TextEditingController();
  final _pushController = TextEditingController();

  final List<String> _log = [];
  List<p2p.PeerInfo> _peers = [];
  List<String> _syncPeers = [];
  List<sync.SyncConflictDto> _conflicts = [];
  String? _statusError;

  @override
  void initState() {
    super.initState();
    _refresh();
    _wireEventStreams();
  }

  @override
  void dispose() {
    _peerIdController.dispose();
    _addrController.dispose();
    _connectController.dispose();
    _pushController.dispose();
    super.dispose();
  }

  void _appendLog(String line) {
    setState(() => _log.insert(0, line));
    if (_log.length > 200) {
      _log.removeRange(200, _log.length);
    }
  }

  Future<void> _wireEventStreams() async {
    try {
      widget.p2pEvents().listen((e) {
        _appendLog('[p2p] ${e.kind.name} ${e.peerId}');
        _refresh();
      });
    } catch (e) {
      _appendLog('[p2p events unavailable: $e]');
    }
    try {
      widget.syncEvents().listen((e) {
        final near = e.nearDuplicate;
        if (near != null) {
          _appendLog(
            '[sync] near-duplicate: "${near.documentId}" ≈ '
            '"${near.relatedTo}" (${(near.similarity * 100).toStringAsFixed(0)}%)',
          );
        } else if (e.conflict != null) {
          _appendLog(
            '[sync] conflict: ${e.conflict!.documentId} -> ${e.conflict!.winner}',
          );
        } else if (e.documentId != null) {
          _appendLog('[sync] transferred ${e.documentId}');
        } else {
          _appendLog('[sync] ${e.kind.name}');
        }
        _refresh();
      });
    } catch (e) {
      _appendLog('[sync events unavailable: $e]');
    }
  }

  void _refresh() {
    setState(() {
      try {
        _peers = widget.listPeers();
        _syncPeers = widget.syncPeers();
        _conflicts = widget.syncConflicts();
        _statusError = null;
      } catch (e) {
        _statusError = '$e';
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('P2P & Sync')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _section('Identity', [
            Text('Local peer id: ${widget.localPeerId()}'),
            if (_statusError != null)
              Text(
                'Error: $_statusError',
                style: const TextStyle(color: Colors.red),
              ),
          ]),
          _section('Discovered peers', [
            if (_peers.isEmpty)
              const Text('No peers discovered.')
            else
              for (final p in _peers)
                ListTile(
                  dense: true,
                  title: Text(p.id),
                  subtitle: Text('${p.state.name}\n${p.addresses.join('\n')}'),
                ),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _peerIdController,
                    decoration: const InputDecoration(labelText: 'Peer id'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _addrController,
                    decoration: const InputDecoration(labelText: 'Multiaddr'),
                  ),
                ),
                IconButton(
                  tooltip: 'Connect',
                  icon: const Icon(Icons.link),
                  onPressed: () {
                    widget.connectPeer(
                      _peerIdController.text,
                      _addrController.text,
                    );
                    _appendLog('[p2p] dialing ${_peerIdController.text}');
                  },
                ),
              ],
            ),
          ]),
          _section('Sync peers', [
            if (_syncPeers.isEmpty)
              const Text('No sync peers connected.')
            else
              Text(_syncPeers.join(', ')),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _connectController,
                    decoration: const InputDecoration(
                      labelText: 'Peer id to sync with',
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Register sync peer',
                  icon: const Icon(Icons.add),
                  onPressed: () {
                    widget.syncStart();
                    widget.syncConnect(_connectController.text);
                    _appendLog('[sync] connected ${_connectController.text}');
                    _refresh();
                  },
                ),
              ],
            ),
          ]),
          _section('Actions', [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  icon: const Icon(Icons.refresh),
                  label: const Text('Refresh'),
                  onPressed: _refresh,
                ),
                OutlinedButton.icon(
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('Start sync'),
                  onPressed: () {
                    widget.syncStart();
                    _appendLog('[sync] started');
                  },
                ),
                OutlinedButton.icon(
                  icon: const Icon(Icons.download),
                  label: const Text('Pull (reconcile)'),
                  onPressed: () {
                    final results = widget.syncPull();
                    _appendLog(
                      '[sync] pull -> ${results.length} resolution(s)',
                    );
                    _refresh();
                  },
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _pushController,
                    decoration: const InputDecoration(
                      labelText: 'Document id to push',
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Push document',
                  icon: const Icon(Icons.upload),
                  onPressed: () {
                    widget.syncPush(_pushController.text);
                    _appendLog('[sync] pushed ${_pushController.text}');
                  },
                ),
              ],
            ),
          ]),
          _section('Conflicts requiring resolution', [
            if (_conflicts.isEmpty)
              const Text('None.')
            else
              for (final c in _conflicts)
                ListTile(
                  dense: true,
                  title: Text(c.documentId),
                  subtitle: Text(
                    'winner: ${c.winner} · kind: ${c.kind.name}\n'
                    'local=${c.localChecksum}\nremote=${c.remoteChecksum}'
                    '${c.forkedDocumentId != null ? '\nfork=${c.forkedDocumentId}' : ''}',
                  ),
                ),
          ]),
          _section('Event log', [
            if (_log.isEmpty)
              const Text('No events yet.')
            else
              for (final line in _log)
                Text(line, style: const TextStyle(fontSize: 12)),
          ]),
        ],
      ),
    );
  }

  Widget _section(String title, List<Widget> children) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          ...children,
        ],
      ),
    );
  }
}
