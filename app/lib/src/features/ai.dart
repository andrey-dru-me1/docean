/// Pluggable AI providers (mirrors `core::ai::AiProvider`).
///
/// The rest of the system depends only on [AiProvider]; concrete providers are
/// selected via configuration and injected at runtime.
library;

class ChatMessage {
  const ChatMessage({required this.role, required this.content});

  final String role;
  final String content;
}

class CompletionRequest {
  const CompletionRequest({
    required this.model,
    required this.messages,
    this.maxTokens,
    this.temperature,
  });

  final String model;
  final List<ChatMessage> messages;
  final int? maxTokens;
  final double? temperature;
}

class Usage {
  const Usage({this.promptTokens = 0, this.completionTokens = 0});

  final int promptTokens;
  final int completionTokens;
}

class CompletionResponse {
  const CompletionResponse({required this.content, this.usage});

  final String content;
  final Usage? usage;
}

/// A single provider implementation (e.g. OpenAI-compatible, Anthropic, Ollama).
abstract interface class AiProvider {
  String get name;

  Future<CompletionResponse> complete(CompletionRequest request);
}
