import 'package:flutter/material.dart';

import 'rust/api/health.dart';
import 'rust_health.dart';

/// Root widget. The health probe is injectable so widget tests can run
/// headlessly without a native library.
class DocerApp extends StatelessWidget {
  const DocerApp({super.key, this.healthCheck = defaultHealthCheck});

  final HealthCheckFn healthCheck;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Docer',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
        useMaterial3: true,
      ),
      home: HomeScreen(healthCheck: healthCheck),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.healthCheck});

  final HealthCheckFn healthCheck;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  HealthStatus? _status;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _probe();
  }

  void _probe() {
    try {
      _status = widget.healthCheck();
      _error = null;
    } catch (e) {
      _status = null;
      _error = e;
    }
  }

  void _refresh() {
    setState(_probe);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Docer')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.folder_shared_outlined, size: 72),
              const SizedBox(height: 16),
              const Text(
                'Digital document storage & organization',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 18),
              ),
              const SizedBox(height: 32),
              _buildStatus(),
              const SizedBox(height: 16),
              TextButton.icon(
                onPressed: _refresh,
                icon: const Icon(Icons.refresh),
                label: const Text('Re-run health check'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStatus() {
    if (_error != null) {
      return Text(
        'Engine error: $_error',
        textAlign: TextAlign.center,
        style: const TextStyle(color: Colors.red),
      );
    }
    final status = _status;
    if (status == null) {
      return const CircularProgressIndicator();
    }
    final ok = status.ok;
    return Column(
      children: [
        Text(
          'Rust core: ${ok ? 'OK' : 'DEGRADED'}',
          style: TextStyle(
            fontWeight: FontWeight.bold,
            color: ok ? Colors.green : Colors.orange,
          ),
        ),
        const SizedBox(height: 8),
        Text('${status.engine} v${status.engineVersion} on ${status.platform}'),
        const SizedBox(height: 4),
        Text('timestamp_ms=${status.timestampMs}'),
      ],
    );
  }
}
