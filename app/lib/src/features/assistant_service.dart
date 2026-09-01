/// A thin, typed facade over the generated assistant bindings for streaming
/// retrieved-augmented answers.
///
/// Isolates the UI from the generated top-level functions and delivers a simple
/// contract: a `Stream<List<String>>` of answer tokens plus a final
/// `done` event carrying the citations. Tests inject a fake implementation,
/// so widgets can be exercised without the native library.
library;

import '../rust/api/assistant.dart' as bridge;
import '../rust/api/assistant.dart' show DocumentRefDto;

export '../rust/api/assistant.dart'
    show AssistantEventKindDto, AssistantStreamEventDto, DocumentRefDto;

/// One step of an assistant reply: either more answer text or the final
/// citations.
sealed class AssistantChunk {
  const AssistantChunk();
}

/// Additional answer text (may be empty while the model is warming up).
class AssistantTokens extends AssistantChunk {
  const AssistantTokens(this.text);

  final String text;
}

/// The answer finished; `references` are the citations the answer points at.
class AssistantDone extends AssistantChunk {
  const AssistantDone(this.references);

  final List<DocumentRefDto> references;
}

/// How the assistant answers a question. Abstract so the UI (and tests) can
/// substitute a fake stream without bridging to Rust.
abstract interface class AssistantService {
  /// Stream answer tokens, then a final [AssistantDone] carrying citations.
  Stream<AssistantChunk> ask(String question);

  /// Clear the conversation history held by the core.
  void clearHistory();
}

/// The default service backed by the Rust bridge.
class BridgeAssistantService implements AssistantService {
  const BridgeAssistantService();

  @override
  Stream<AssistantChunk> ask(String question) =>
      bridge.assistantAskStream(question: question).map((event) {
        return switch (event.kind) {
          bridge.AssistantEventKindDto.token => AssistantTokens(
            event.token ?? '',
          ),
          bridge.AssistantEventKindDto.done => AssistantDone(event.references),
        };
      });

  @override
  void clearHistory() => bridge.assistantClearHistory();
}
