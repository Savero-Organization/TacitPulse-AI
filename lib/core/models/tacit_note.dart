class SopDraftStep {
  const SopDraftStep({required this.order, required this.title, required this.detail, required this.confirmed});
  final int order;
  final String title;
  final String detail;
  final bool confirmed;
}

enum SopDraftStatus { drafting, ready, exported }

/// Catatan tacit hasil rekaman suara teknisi yang siap
/// dikonversi menjadi draft SOP terstruktur.
class TacitNote {
  const TacitNote({
    required this.id,
    required this.title,
    required this.technician,
    required this.line,
    required this.durationSeconds,
    required this.recordedAt,
    required this.waveform,
    required this.transcribedText,
    this.sopSteps = const [],
    this.status = SopDraftStatus.drafting,
  });

  final String id;
  final String title;
  final String technician;
  final String line;
  final int durationSeconds;
  final DateTime recordedAt;
  final List<double> waveform;
  final String transcribedText;
  final List<SopDraftStep> sopSteps;
  final SopDraftStatus status;
}