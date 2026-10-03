// sop_draft_model.dart — model draft SOP hasil parsing output LLM Qwen.

library;

/// Satu langkah prosedur dalam [SopDraftModel].
class SopStep {
  const SopStep({
    required this.stepNumber,
    required this.action,
    this.safetyNote,
  });

  final int stepNumber;
  final String action;
  final String? safetyNote;

  factory SopStep.fromJson(Map<String, dynamic> json, {int fallbackNumber = 1}) {
    return SopStep(
      stepNumber: _asInt(json['stepNumber']) ?? fallbackNumber,
      action: _asString(json['action']) ?? '',
      safetyNote: _asString(json['safetyNote']),
    );
  }

  Map<String, dynamic> toJson() => {
        'stepNumber': stepNumber,
        'action': action,
        if (safetyNote != null) 'safetyNote': safetyNote,
      };

  SopStep copyWith({
    int? stepNumber,
    String? action,
    String? safetyNote,
    bool clearSafetyNote = false,
  }) {
    return SopStep(
      stepNumber: stepNumber ?? this.stepNumber,
      action: action ?? this.action,
      safetyNote: clearSafetyNote ? null : (safetyNote ?? this.safetyNote),
    );
  }
}

/// Draft SOP terstruktur yang diturunkan dari transkripsi suara teknisi.
class SopDraftModel {
  const SopDraftModel({
    required this.title,
    required this.equipment,
    required this.category,
    required this.summary,
    required this.hazards,
    required this.requiredTools,
    required this.steps,
  });

  final String title;
  final String equipment;
  final String category;
  final String summary;
  final List<String> hazards;
  final List<String> requiredTools;
  final List<SopStep> steps;

  factory SopDraftModel.fromJson(Map<String, dynamic> json) {
    return SopDraftModel(
      title: _asString(json['title']) ?? '',
      equipment: _asString(json['equipment']) ?? '',
      category: _asString(json['category']) ?? '',
      summary: _asString(json['summary']) ?? '',
      hazards: _asStringList(json['hazards']),
      requiredTools: _asStringList(json['requiredTools']),
      steps: _asSteps(json['steps']),
    );
  }

  Map<String, dynamic> toJson() => {
        'title': title,
        'equipment': equipment,
        'category': category,
        'summary': summary,
        'hazards': List<String>.of(hazards),
        'requiredTools': List<String>.of(requiredTools),
        'steps': steps.map((s) => s.toJson()).toList(),
      };

  SopDraftModel copyWith({
    String? title,
    String? equipment,
    String? category,
    String? summary,
    List<String>? hazards,
    List<String>? requiredTools,
    List<SopStep>? steps,
  }) {
    return SopDraftModel(
      title: title ?? this.title,
      equipment: equipment ?? this.equipment,
      category: category ?? this.category,
      summary: summary ?? this.summary,
      hazards: hazards ?? this.hazards,
      requiredTools: requiredTools ?? this.requiredTools,
      steps: steps ?? this.steps,
    );
  }
}

String? _asString(Object? value) {
  if (value is String) return value;
  if (value == null) return null;
  return value.toString();
}

int? _asInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value);
  return null;
}

List<String> _asStringList(Object? value) {
  if (value is List) {
    return value
        .map((e) => e is String ? e : e?.toString())
        .whereType<String>()
        .toList(growable: false);
  }
  return const [];
}

List<SopStep> _asSteps(Object? value) {
  if (value is List) {
    final steps = <SopStep>[];
    for (final entry in value) {
      if (entry is Map) {
        steps.add(SopStep.fromJson(
          entry.cast<String, dynamic>(),
          fallbackNumber: steps.length + 1,
        ));
      }
    }
    return steps;
  }
  return const [];
}
