part of 'chat_providers.dart';

// Available tools provider
final availableToolsProvider =
    NotifierProvider<AvailableToolsNotifier, List<String>>(
      AvailableToolsNotifier.new,
    );

// Web search enabled state for API-based web search
final webSearchEnabledProvider =
    NotifierProvider<WebSearchEnabledNotifier, bool>(
      WebSearchEnabledNotifier.new,
    );

// Image generation enabled state - behaves like web search
final imageGenerationEnabledProvider =
    NotifierProvider<ImageGenerationEnabledNotifier, bool>(
      ImageGenerationEnabledNotifier.new,
    );

// Code interpreter (execute_code) enabled state - behaves like web search
final codeInterpreterEnabledProvider =
    NotifierProvider<CodeInterpreterEnabledNotifier, bool>(
      CodeInterpreterEnabledNotifier.new,
    );

// Vision capable models provider
final visionCapableModelsProvider =
    NotifierProvider<VisionCapableModelsNotifier, List<String>>(
      VisionCapableModelsNotifier.new,
    );

// File upload capable models provider
final fileUploadCapableModelsProvider =
    NotifierProvider<FileUploadCapableModelsNotifier, List<String>>(
      FileUploadCapableModelsNotifier.new,
    );

class AvailableToolsNotifier extends Notifier<List<String>> {
  @override
  List<String> build() => [];

  void set(List<String> tools) => state = List<String>.from(tools);
}

class WebSearchEnabledNotifier extends Notifier<bool> {
  @override
  bool build() => ref.watch(_chatFeatureDefaultsProvider).webSearchEnabled;

  void set(bool value) {
    state = value;
    unawaited(
      ref.read(appSettingsProvider.notifier).setChatWebSearchEnabled(value),
    );
  }
}

class ImageGenerationEnabledNotifier extends Notifier<bool> {
  @override
  bool build() =>
      ref.watch(_chatFeatureDefaultsProvider).imageGenerationEnabled;

  void set(bool value) {
    state = value;
    unawaited(
      ref
          .read(appSettingsProvider.notifier)
          .setChatImageGenerationEnabled(value),
    );
  }
}

class CodeInterpreterEnabledNotifier extends Notifier<bool> {
  @override
  bool build() => ref.watch(_chatFeatureDefaultsProvider).codeInterpreterEnabled;

  void set(bool value) {
    state = value;
    unawaited(
      ref
          .read(appSettingsProvider.notifier)
          .setChatCodeInterpreterEnabled(value),
    );
    // Pre-boot the on-device Pyodide runtime so the first execute:python
    // event doesn't pay the cold-start cost while the server awaits the ack.
    if (value) {
      PyodideCodeRunner.instance.warmUp();
    }
  }
}

class VisionCapableModelsNotifier extends Notifier<List<String>> {
  @override
  List<String> build() {
    final selectedModel = ref.watch(selectedModelProvider);
    if (selectedModel == null) {
      return [];
    }

    if (selectedModel.isMultimodal == true) {
      return [selectedModel.id];
    }

    // For now, assume all models support vision unless explicitly marked
    return [selectedModel.id];
  }
}

class FileUploadCapableModelsNotifier extends Notifier<List<String>> {
  @override
  List<String> build() {
    final selectedModel = ref.watch(selectedModelProvider);
    if (selectedModel == null) {
      return [];
    }

    // For now, assume all models support file upload
    return [selectedModel.id];
  }
}
