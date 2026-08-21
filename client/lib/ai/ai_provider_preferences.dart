import 'package:shared_preferences/shared_preferences.dart';

import 'ai_provider.dart';
import 'anthropic_provider.dart';
import 'openai_compatible_provider.dart';

/// AI Modelling workstream 1: which AI provider is active, plus each
/// provider slot's own `baseUrl`/`apiKey`/`model` fields - mirrors
/// `ApiConfig`'s own `shared_preferences`-backed, load-then-read-getters
/// pattern exactly (`client/lib/config.dart`).
class AiProviderPreferences {
  AiProviderPreferences._();

  static const String activeProviderPrefKey = 'ai_active_provider';
  static const String localBaseUrlPrefKey = 'ai_local_base_url';
  static const String localApiKeyPrefKey = 'ai_local_api_key';
  static const String localModelPrefKey = 'ai_local_model';
  // Workstream 10 (`10-image-input.md`): opt-in only - unlike
  // `supportsStructuredOutput`, this class has no way to verify an
  // arbitrary OpenAI-compatible local/free-tier endpoint's model actually
  // accepts images, so it stays `false` until the user explicitly confirms
  // it via the settings screen's own checkbox.
  static const String localSupportsVisionPrefKey = 'ai_local_supports_vision';
  static const String openAiApiKeyPrefKey = 'ai_openai_api_key';
  static const String openAiModelPrefKey = 'ai_openai_model';
  static const String anthropicApiKeyPrefKey = 'ai_anthropic_api_key';
  static const String anthropicModelPrefKey = 'ai_anthropic_model';

  /// Fixed per `01-provider-abstraction.md`'s own OpenAI cloud slot.
  static const String openAiBaseUrl = 'https://api.openai.com/v1';

  static const String defaultActiveProvider = 'local';

  static String _activeProvider = defaultActiveProvider;
  static String _localBaseUrl = '';
  static String? _localApiKey;
  static String _localModel = '';
  static bool _localSupportsVision = false;
  static String _openAiApiKey = '';
  static String _openAiModel = '';
  static String _anthropicApiKey = '';
  static String _anthropicModel = '';

  static String get activeProvider => _activeProvider;
  static String get localBaseUrl => _localBaseUrl;
  static String? get localApiKey => _localApiKey;
  static String get localModel => _localModel;
  static bool get localSupportsVision => _localSupportsVision;
  static String get openAiApiKey => _openAiApiKey;
  static String get openAiModel => _openAiModel;
  static String get anthropicApiKey => _anthropicApiKey;
  static String get anthropicModel => _anthropicModel;

  static Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _activeProvider = prefs.getString(activeProviderPrefKey) ?? defaultActiveProvider;
    _localBaseUrl = prefs.getString(localBaseUrlPrefKey) ?? '';
    _localApiKey = prefs.getString(localApiKeyPrefKey);
    _localModel = prefs.getString(localModelPrefKey) ?? '';
    _localSupportsVision = prefs.getBool(localSupportsVisionPrefKey) ?? false;
    _openAiApiKey = prefs.getString(openAiApiKeyPrefKey) ?? '';
    _openAiModel = prefs.getString(openAiModelPrefKey) ?? '';
    _anthropicApiKey = prefs.getString(anthropicApiKeyPrefKey) ?? '';
    _anthropicModel = prefs.getString(anthropicModelPrefKey) ?? '';
  }

  static Future<void> setActiveProvider(String provider) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(activeProviderPrefKey, provider);
    _activeProvider = provider;
  }

  /// [apiKey] is nullable - local typically has none (a bare, unauthenticated
  /// endpoint), unlike the cloud slots below. [supportsVision] defaults to
  /// `false` (workstream 10's opt-in-only stance - see
  /// [localSupportsVisionPrefKey]'s own doc comment).
  static Future<void> saveLocal({
    required String baseUrl,
    String? apiKey,
    required String model,
    bool supportsVision = false,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(localBaseUrlPrefKey, baseUrl);
    if (apiKey == null || apiKey.isEmpty) {
      await prefs.remove(localApiKeyPrefKey);
    } else {
      await prefs.setString(localApiKeyPrefKey, apiKey);
    }
    await prefs.setString(localModelPrefKey, model);
    await prefs.setBool(localSupportsVisionPrefKey, supportsVision);
    _localBaseUrl = baseUrl;
    _localApiKey = (apiKey == null || apiKey.isEmpty) ? null : apiKey;
    _localModel = model;
    _localSupportsVision = supportsVision;
  }

  static Future<void> saveOpenAi({required String apiKey, required String model}) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(openAiApiKeyPrefKey, apiKey);
    await prefs.setString(openAiModelPrefKey, model);
    _openAiApiKey = apiKey;
    _openAiModel = model;
  }

  static Future<void> saveAnthropic({required String apiKey, required String model}) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(anthropicApiKeyPrefKey, apiKey);
    await prefs.setString(anthropicModelPrefKey, model);
    _anthropicApiKey = apiKey;
    _anthropicModel = model;
  }

  /// Mirrors `ApiConfig.isConfigured`'s own shape: whether the *active*
  /// provider slot has enough set to actually make a call, not just whether
  /// `load()` has run - a genuine first-time user (default `local` slot,
  /// empty `baseUrl`) should be guarded against, not just an unloaded state.
  static bool get isActiveProviderConfigured {
    switch (_activeProvider) {
      case 'openai':
        return _openAiApiKey.isNotEmpty;
      case 'anthropic':
        return _anthropicApiKey.isNotEmpty;
      case 'local':
      default:
        return _localBaseUrl.isNotEmpty;
    }
  }

  /// Builds the right concrete provider from whatever [load] last populated -
  /// every consumer above the interface calls this and `AiProvider` only,
  /// never a concrete provider type directly.
  static AiProvider get active {
    switch (_activeProvider) {
      case 'openai':
        return OpenAiCompatibleProvider(
          baseUrl: openAiBaseUrl,
          apiKey: _openAiApiKey,
          model: _openAiModel,
          supportsStructuredOutput: true,
          supportsVision: true, // OpenAI cloud's own current models are multimodal
        );
      case 'anthropic':
        return AnthropicProvider(apiKey: _anthropicApiKey, model: _anthropicModel);
      case 'local':
      default:
        return OpenAiCompatibleProvider(
          baseUrl: _localBaseUrl,
          apiKey: _localApiKey,
          model: _localModel,
          supportsVision: _localSupportsVision,
        );
    }
  }
}
