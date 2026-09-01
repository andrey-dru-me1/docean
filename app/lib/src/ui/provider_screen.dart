import 'package:flutter/material.dart';

import '../features/provider_service.dart'
    show ActiveProviderInfo, ProviderKind, ProviderService, ProviderSettings;

/// Provider configuration screen: select and configure the AI provider.
///
/// Lists every backend, shows which is active, lets the user pick a provider
/// and model, edit base URL, and store/remove an API key. Degrades gracefully
/// when the engine is unavailable or no provider is configured.
class ProviderScreen extends StatefulWidget {
  const ProviderScreen({super.key, required this.providerService});

  final ProviderService providerService;

  @override
  State<ProviderScreen> createState() => _ProviderScreenState();
}

class _ProviderScreenState extends State<ProviderScreen> {
  List<ProviderSettings> _providers = [];
  ActiveProviderInfo? _active;
  Object? _error;
  bool _loading = true;

  // Editing state for the selected provider.
  ProviderSettings? _editing;
  final _modelController = TextEditingController();
  final _baseUrlController = TextEditingController();
  final _apiKeyController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _modelController.dispose();
    _baseUrlController.dispose();
    _apiKeyController.dispose();
    super.dispose();
  }

  void _load() {
    setState(() => _loading = true);
    try {
      final providers = widget.providerService.listProviders();
      final active = widget.providerService.activeProvider();
      if (!mounted) return;
      setState(() {
        _providers = providers;
        _active = active;
        _error = null;
        _loading = false;
        _editing = providers
            .where((p) => p.kind.name == active.kind)
            .firstOrNull;
        _applyEditingToControllers();
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  void _applyEditingToControllers() {
    final p = _editing;
    _modelController.text = p?.model ?? '';
    _baseUrlController.text = p?.baseUrl ?? '';
    _apiKeyController.clear();
  }

  void _selectEditing(ProviderSettings p) {
    setState(() {
      _editing = p;
      _applyEditingToControllers();
    });
  }

  Future<void> _activate() async {
    final p = _editing;
    if (p == null) return;
    try {
      final updated = widget.providerService.selectProvider(
        p.kind.name,
        model: _modelController.text.trim().isEmpty
            ? p.model
            : _modelController.text.trim(),
      );
      if (!mounted) return;
      setState(() => _active = updated);
      _load();
    } catch (e) {
      _showError('Could not activate provider', e);
    }
  }

  Future<void> _save() async {
    final p = _editing;
    if (p == null) return;
    try {
      final updated = _copyWithEdited(p);
      widget.providerService.saveProviderSettings(updated);
      // Persist the key if the user entered one.
      final key = _apiKeyController.text.trim();
      if (key.isNotEmpty) {
        widget.providerService.setApiKey(p.kind.name, key);
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Provider configuration saved')),
      );
      _load();
    } catch (e) {
      _showError('Could not save provider', e);
    }
  }

  ProviderSettings _copyWithEdited(ProviderSettings p) => ProviderSettings(
    kind: p.kind,
    baseUrl: _baseUrlController.text.trim().isEmpty
        ? p.baseUrl
        : _baseUrlController.text.trim(),
    model: _modelController.text.trim().isEmpty
        ? p.model
        : _modelController.text.trim(),
    enabled: p.enabled,
    models: p.models,
    hasApiKey: p.hasApiKey,
  );

  Future<void> _removeKey() async {
    final p = _editing;
    if (p == null) return;
    try {
      widget.providerService.removeApiKey(p.kind.name);
      _apiKeyController.clear();
      _load();
    } catch (e) {
      _showError('Could not remove API key', e);
    }
  }

  void _showError(String title, Object e) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('$title: $e')));
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 64),
              const SizedBox(height: 16),
              const Text('Provider configuration unavailable'),
              const SizedBox(height: 8),
              Text(
                '$_error',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              TextButton(onPressed: _load, child: const Text('Retry')),
            ],
          ),
        ),
      );
    }

    final scheme = Theme.of(context).colorScheme;
    final activeKind = _active?.kind;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (_active == null)
          Card(
            color: scheme.tertiaryContainer,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Icon(Icons.info_outline, color: scheme.onTertiaryContainer),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Text(
                      'No AI provider is configured. Select one below to enable '
                      'generative answers in the assistant.',
                    ),
                  ),
                ],
              ),
            ),
          ),
        const SizedBox(height: 8),
        Text('Providers', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        for (final p in _providers)
          _buildProviderTile(
            p,
            active: p.kind.name == activeKind,
            onSelect: () => _selectEditing(p),
          ),
        const SizedBox(height: 16),
        if (_editing != null) _buildEditor(),
        const SizedBox(height: 48),
      ],
    );
  }

  Widget _buildProviderTile(
    ProviderSettings p, {
    required bool active,
    required VoidCallback onSelect,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: ListTile(
        leading: CircleAvatar(child: Icon(_iconFor(p.kind))),
        title: Text(_labelFor(p.kind)),
        subtitle: Text('Model: ${p.model}'),
        trailing: active
            ? Chip(
                avatar: const Icon(Icons.check, size: 14),
                label: const Text('Active'),
                backgroundColor: scheme.primaryContainer,
                labelStyle: TextStyle(color: scheme.onPrimaryContainer),
              )
            : const SizedBox.shrink(),
        onTap: onSelect,
      ),
    );
  }

  Widget _buildEditor() {
    final p = _editing!;
    final disabled = p.kind == ProviderKind.builtin;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Configure ${_labelFor(p.kind)}',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _modelController,
              decoration: const InputDecoration(
                labelText: 'Model',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _baseUrlController,
              enabled: !disabled,
              decoration: InputDecoration(
                labelText: 'Base URL',
                hintText: 'http://…',
                border: const OutlineInputBorder(),
                helperText: disabled
                    ? 'The built-in local model does not need a URL.'
                    : null,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _apiKeyController,
              obscureText: true,
              enabled: !disabled,
              decoration: InputDecoration(
                labelText: 'API key',
                hintText: p.hasApiKey ? '•••••••• (stored)' : 'Optional',
                border: const OutlineInputBorder(),
                suffixIcon: p.hasApiKey && !disabled
                    ? IconButton(
                        tooltip: 'Remove stored key',
                        onPressed: _removeKey,
                        icon: const Icon(Icons.delete_outline),
                      )
                    : null,
              ),
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                OutlinedButton(
                  onPressed: _activate,
                  child: const Text('Activate'),
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  onPressed: _save,
                  icon: const Icon(Icons.save_outlined),
                  label: const Text('Save'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  IconData _iconFor(ProviderKind kind) => switch (kind) {
    ProviderKind.builtin => Icons.memory,
    ProviderKind.ollama => Icons.pets,
    ProviderKind.openai => Icons.cloud_outlined,
  };

  String _labelFor(ProviderKind kind) => switch (kind) {
    ProviderKind.builtin => 'Built-in (local)',
    ProviderKind.ollama => 'Ollama (local server)',
    ProviderKind.openai => 'OpenAI-compatible',
  };
}
