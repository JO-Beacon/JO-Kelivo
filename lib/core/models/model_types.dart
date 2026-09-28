import 'package:flutter/foundation.dart';

import 'model_spec.dart';

// 模型类型/模态/能力枚举的唯一来源已迁到 model_spec.dart（与上游一致）。
// 这里只做转出，供尚未迁移的旧调用点继续引用。
export 'model_spec.dart' show ModelType, Modality, ModelAbility;

/// 旧版「模型信息」结构。
///
/// 上游已用 [ModelSpec] 取代它；本文件保留它只是为了让尚未迁移的调用点
/// 在 S4 期间继续编译，待请求层全部切到 ModelSpec 后删除。
@immutable
class ModelInfo {
  final String id;
  final String displayName;
  final ModelType type;
  final List<Modality> input;
  final List<Modality> output;
  final List<ModelAbility> abilities;

  static List<Modality> _normalizeModalities(Iterable<Modality> mods) {
    final set = <Modality>{...mods};
    final list = set.toList()..sort((a, b) => a.index.compareTo(b.index));
    return List.unmodifiable(list);
  }

  static List<ModelAbility> _normalizeAbilities(Iterable<ModelAbility> abs) {
    final set = <ModelAbility>{...abs};
    final list = set.toList()..sort((a, b) => a.index.compareTo(b.index));
    return List.unmodifiable(list);
  }

  ModelInfo({
    required this.id,
    required this.displayName,
    this.type = ModelType.chat,
    List<Modality> input = const [Modality.text],
    List<Modality> output = const [Modality.text],
    List<ModelAbility> abilities = const [],
  }) : input = _normalizeModalities(input),
       output = _normalizeModalities(output),
       abilities = _normalizeAbilities(abilities);

  ModelInfo copyWith({
    String? id,
    String? displayName,
    ModelType? type,
    List<Modality>? input,
    List<Modality>? output,
    List<ModelAbility>? abilities,
  }) {
    return ModelInfo(
      id: id ?? this.id,
      displayName: displayName ?? this.displayName,
      type: type ?? this.type,
      input: input ?? this.input,
      output: output ?? this.output,
      abilities: abilities ?? this.abilities,
    );
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other is ModelInfo &&
            runtimeType == other.runtimeType &&
            id == other.id &&
            displayName == other.displayName &&
            type == other.type &&
            listEquals(input, other.input) &&
            listEquals(output, other.output) &&
            listEquals(abilities, other.abilities));
  }

  @override
  int get hashCode => Object.hash(
    id,
    displayName,
    type,
    Object.hashAll(input),
    Object.hashAll(output),
    Object.hashAll(abilities),
  );
}
