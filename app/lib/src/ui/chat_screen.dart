import 'dart:async';

import 'package:flutter/material.dart';

import '../features/assistant_service.dart'
    show AssistantChunk, AssistantDone, AssistantService, AssistantTokens;
import 'document_view.dart' show DocumentSummary;
import 'widgets.dart' show AiUnavailableBanner;

/// Chat panel: user asks a question, receives a streaming answer with
/// clickable citations that open the referenced documents.
class ChatScreen extends StatefulWidget {
  const ChatScreen({
    super.key,
    required this.assistantService,
    required this.onOpenDocument,
    this.aiAvailable = true,
    this.onConfigureAi,
  });

  final AssistantService assistantService;
  final void Function(DocumentSummary) onOpenDocument;
  final bool aiAvailable;
  final VoidCallback? onConfigureAi;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _Message {
  const _Message({
    required this.role,
    required this.text,
    this.references = const [],
    this.streaming = false,
    this.error = false,
  });

  final String role; // 'user' | 'assistant'
  final String text;
  final List<DocumentRefLike> references;
  final bool streaming;
  final bool error;
}

/// Minimal citation type so the UI doesn't depend on the bridge DTO directly;
/// `openDocument` is wired by the shell.
typedef DocumentRefLike = ({String documentId, String excerpt});

class _ChatScreenState extends State<ChatScreen> {
  final _controller = TextEditingController();
  final _scrollController = ScrollController();
  final List<_Message> _messages = [];
  StreamSubscription<AssistantChunk>? _sub;
  bool _sending = false;
  String _partial = '';

  @override
  void dispose() {
    _sub?.cancel();
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    });
  }

  void _updateStreamingMessage() {
    if (!mounted) return;
    setState(() {
      _messages[_messages.length - 1] = _Message(
        role: 'assistant',
        text: _partial,
        streaming: true,
      );
    });
    _scrollToBottom();
  }

  Future<void> _send() async {
    final question = _controller.text.trim();
    if (question.isEmpty || _sending) return;
    _controller.clear();
    setState(() {
      _messages.add(_Message(role: 'user', text: question));
      _messages.add(
        const _Message(role: 'assistant', text: '', streaming: true),
      );
      _sending = true;
      _partial = '';
    });
    _scrollToBottom();

    try {
      final stream = widget.assistantService.ask(question);
      _sub = stream.listen(
        (chunk) {
          switch (chunk) {
            case AssistantTokens(:final text):
              _partial += text;
              _updateStreamingMessage();
            case AssistantDone(:final references):
              final refs = <DocumentRefLike>[
                for (final r in references)
                  (documentId: r.documentId, excerpt: r.excerpt),
              ];
              setState(() {
                _messages[_messages.length - 1] = _Message(
                  role: 'assistant',
                  text: _partial,
                  references: refs,
                );
                _sending = false;
              });
              _partial = '';
              _scrollToBottom();
          }
        },
        onError: (Object e) {
          setState(() {
            _messages[_messages.length - 1] = _Message(
              role: 'assistant',
              text: 'Sorry, I could not answer that. $e',
              error: true,
            );
            _sending = false;
          });
          _partial = '';
        },
        onDone: () {
          if (_sending) {
            setState(() {
              _messages[_messages.length - 1] = _Message(
                role: 'assistant',
                text: _partial,
              );
              _sending = false;
            });
            _partial = '';
          }
        },
      );
    } catch (e) {
      setState(() {
        _messages[_messages.length - 1] = _Message(
          role: 'assistant',
          text: 'Failed to start the assistant: $e',
          error: true,
        );
        _sending = false;
      });
      _partial = '';
    }
  }

  void _clear() {
    widget.assistantService.clearHistory();
    setState(() => _messages.clear());
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        if (!widget.aiAvailable && widget.onConfigureAi != null)
          AiUnavailableBanner(onConfigure: widget.onConfigureAi),
        Expanded(
          child: _messages.isEmpty
              ? _buildEmpty()
              : ListView.builder(
                  controller: _scrollController,
                  padding: const EdgeInsets.all(16),
                  itemCount: _messages.length,
                  itemBuilder: (context, i) => _buildMessage(_messages[i]),
                ),
        ),
        const Divider(height: 1),
        _buildInput(),
      ],
    );
  }

  Widget _buildEmpty() {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.chat_bubble_outline, size: 64),
            SizedBox(height: 16),
            Text(
              'Ask a question about your documents',
              style: TextStyle(fontSize: 18),
            ),
            SizedBox(height: 8),
            Text(
              'Answers include citations. Click a citation to open the document.',
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMessage(_Message msg) {
    final isUser = msg.role == 'user';
    final scheme = Theme.of(context).colorScheme;
    final align = isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start;
    final bubbleColor = isUser
        ? scheme.primaryContainer
        : scheme.surfaceContainerHighest;
    final bubbleText = isUser ? scheme.onPrimaryContainer : scheme.onSurface;

    if (msg.streaming && msg.text.isEmpty) {
      return Align(
        alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 12),
              Text('Thinking…', style: TextStyle(color: bubbleText)),
            ],
          ),
        ),
      );
    }

    final narrow = MediaQuery.sizeOf(context).width < 700;
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Container(
          constraints: BoxConstraints(
            maxWidth: narrow
                ? double.infinity
                : MediaQuery.sizeOf(context).width * 0.7,
          ),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: bubbleColor,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            crossAxisAlignment: align,
            children: [
              SelectableText(
                msg.text,
                style: TextStyle(color: bubbleText, height: 1.4),
              ),
              if (msg.streaming) ...[
                const SizedBox(height: 6),
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ],
              if (msg.references.isNotEmpty) ...[
                const SizedBox(height: 10),
                Text(
                  'Sources',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: bubbleText.withValues(alpha: 0.8),
                  ),
                ),
                const SizedBox(height: 6),
                for (final ref in msg.references)
                  _CitationChip(ref: ref, onOpen: widget.onOpenDocument),
              ],
              if (msg.error) ...[
                const SizedBox(height: 6),
                Icon(Icons.error_outline, size: 16, color: scheme.error),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildInput() {
    final canSend = _controller.text.trim().isNotEmpty && !_sending;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: TextField(
                controller: _controller,
                minLines: 1,
                maxLines: 4,
                textInputAction: TextInputAction.send,
                onChanged: (_) => setState(() {}),
                onSubmitted: (_) => _send(),
                decoration: InputDecoration(
                  hintText: 'Ask about your documents…',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(24),
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 10,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filled(
              tooltip: 'Send',
              onPressed: canSend ? _send : null,
              icon: const Icon(Icons.send),
            ),
            const SizedBox(width: 4),
            IconButton(
              tooltip: 'Clear chat',
              onPressed: _messages.isEmpty ? null : _clear,
              icon: const Icon(Icons.delete_sweep_outlined),
            ),
          ],
        ),
      ),
    );
  }
}

/// A clickable citation chip that opens the referenced document.
class _CitationChip extends StatelessWidget {
  const _CitationChip({required this.ref, required this.onOpen});

  final DocumentRefLike ref;
  final void Function(DocumentSummary) onOpen;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: ActionChip(
        avatar: const Icon(Icons.description_outlined, size: 16),
        label: Text(ref.documentId, overflow: TextOverflow.ellipsis),
        tooltip: ref.excerpt.isEmpty ? 'Open document' : ref.excerpt,
        onPressed: () => onOpen(
          DocumentSummary(
            id: ref.documentId,
            title: ref.documentId,
            snippet: ref.excerpt,
          ),
        ),
      ),
    );
  }
}
