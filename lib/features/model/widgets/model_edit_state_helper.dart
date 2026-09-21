import '../../../core/models/model_types.dart';

/// 目录同步得到的账号元数据不在模型表单中编辑；保存时从最新覆盖项读取，
/// 这样编辑期间发生的目录刷新也不会被旧表单覆盖。
Map<String, dynamic> modelSyncMetadata(Map<String, dynamic> override) => {
  for (final key in const [
    'oauthProtocol',
    'oauthThinkingMode',
    'oauthThinkingRequired',
    'oauthThinkingEfforts',
    'oauthThinkingDefaultEffort',
  ])
    if (override.containsKey(key)) key: override[key],
};

class ModelTypeSwitchResult {
  const ModelTypeSwitchResult({
    required this.input,
    required this.output,
    required this.abilities,
    required this.cachedChatInput,
    required this.cachedChatOutput,
    required this.cachedChatAbilities,
    required this.cachedEmbeddingInput,
  });

  final Set<Modality> input;
  final Set<Modality> output;
  final Set<ModelAbility> abilities;
  final Set<Modality>? cachedChatInput;
  final Set<Modality>? cachedChatOutput;
  final Set<ModelAbility>? cachedChatAbilities;
  final Set<Modality>? cachedEmbeddingInput;
}

class ModelEditTypeSwitch {
  /// 应用模型类型切换并返回新集合（不进行原地修改）。
  static ModelTypeSwitchResult apply({
    required ModelType prev,
    required ModelType next,
    required Set<Modality> input,
    required Set<Modality> output,
    required Set<ModelAbility> abilities,
    required Set<Modality>? cachedChatInput,
    required Set<Modality>? cachedChatOutput,
    required Set<ModelAbility>? cachedChatAbilities,
    required Set<Modality>? cachedEmbeddingInput,
  }) {
    Set<Modality> ensureText(Set<Modality> mods) {
      if (!mods.contains(Modality.text)) mods.add(Modality.text);
      return mods;
    }

    Set<T> freezeSet<T>(Set<T> set) => Set.unmodifiable(Set<T>.from(set));
    Set<T>? freezeNullableSet<T>(Set<T>? set) =>
        set == null ? null : freezeSet(set);

    if (prev == next) {
      return ModelTypeSwitchResult(
        input: freezeSet(input),
        output: freezeSet(output),
        abilities: freezeSet(abilities),
        cachedChatInput: freezeNullableSet(cachedChatInput),
        cachedChatOutput: freezeNullableSet(cachedChatOutput),
        cachedChatAbilities: freezeNullableSet(cachedChatAbilities),
        cachedEmbeddingInput: freezeNullableSet(cachedEmbeddingInput),
      );
    }

    var nextCachedChatInput = cachedChatInput;
    var nextCachedChatOutput = cachedChatOutput;
    var nextCachedChatAbilities = cachedChatAbilities;
    var nextCachedEmbeddingInput = cachedEmbeddingInput;

    var nextInput = {...input};
    var nextOutput = {...output};
    var nextAbilities = {...abilities};

    if (prev == ModelType.chat && next == ModelType.embedding) {
      nextCachedChatInput = {...input};
      nextCachedChatOutput = {...output};
      nextCachedChatAbilities = {...abilities};
    }
    if (prev == ModelType.embedding && next == ModelType.chat) {
      nextCachedEmbeddingInput = {...input};
    }

    if (next == ModelType.embedding) {
      nextAbilities.clear();
      final resolvedInput = {
        ...(nextCachedEmbeddingInput ?? const {Modality.text}),
      };
      nextInput
        ..clear()
        ..addAll(resolvedInput);
      nextInput = ensureText(nextInput);
      nextOutput
        ..clear()
        ..add(Modality.text);
      return ModelTypeSwitchResult(
        input: freezeSet(nextInput),
        output: freezeSet(nextOutput),
        abilities: freezeSet(nextAbilities),
        cachedChatInput: freezeNullableSet(nextCachedChatInput),
        cachedChatOutput: freezeNullableSet(nextCachedChatOutput),
        cachedChatAbilities: freezeNullableSet(nextCachedChatAbilities),
        cachedEmbeddingInput: freezeNullableSet(nextCachedEmbeddingInput),
      );
    }

    if (prev == ModelType.embedding && next == ModelType.chat) {
      nextInput
        ..clear()
        ..addAll(nextCachedChatInput ?? const {Modality.text});
      nextInput = ensureText(nextInput);

      nextOutput
        ..clear()
        ..addAll(nextCachedChatOutput ?? const {Modality.text});
      nextOutput = ensureText(nextOutput);

      nextAbilities
        ..clear()
        ..addAll(nextCachedChatAbilities ?? const <ModelAbility>{});
    }

    return ModelTypeSwitchResult(
      input: freezeSet(nextInput),
      output: freezeSet(nextOutput),
      abilities: freezeSet(nextAbilities),
      cachedChatInput: freezeNullableSet(nextCachedChatInput),
      cachedChatOutput: freezeNullableSet(nextCachedChatOutput),
      cachedChatAbilities: freezeNullableSet(nextCachedChatAbilities),
      cachedEmbeddingInput: freezeNullableSet(nextCachedEmbeddingInput),
    );
  }
}
