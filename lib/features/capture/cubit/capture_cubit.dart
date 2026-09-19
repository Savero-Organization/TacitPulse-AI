import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/models/tacit_note.dart';
import '../../mock_data.dart';

enum CaptureStatus { idle, recording, transcribing, drafting }

class CaptureState {
  const CaptureState({
    this.notes = const [],
    this.status = CaptureStatus.idle,
    this.waveform = const [],
    this.recordingSeconds = 0,
    this.transcribing = '',
    this.activeDraft,
  });

  final List<TacitNote> notes;
  final CaptureStatus status;
  final List<double> waveform;
  final int recordingSeconds;
  final String transcribing;
  final TacitNote? activeDraft;

  CaptureState copyWith({
    List<TacitNote>? notes,
    CaptureStatus? status,
    List<double>? waveform,
    int? recordingSeconds,
    String? transcribing,
    TacitNote? activeDraft,
  }) {
    return CaptureState(
      notes: notes ?? this.notes,
      status: status ?? this.status,
      waveform: waveform ?? this.waveform,
      recordingSeconds: recordingSeconds ?? this.recordingSeconds,
      transcribing: transcribing ?? this.transcribing,
      activeDraft: activeDraft ?? this.activeDraft,
    );
  }
}

/// Cubit perekaman tacit: waveform visualizer realtime + konversi
/// voice note menjadi draft SOP terstruktur (whisper.cpp nanti).
class CaptureCubit extends Cubit<CaptureState> {
  CaptureCubit() : super(CaptureState(notes: MockData.buildNotes()));

  final math.Random _rnd = math.Random(3);
  Timer? _waveTimer;
  Timer? _recordTicker;
  int _sampleIdx = 0;

  void startRecording() {
    if (state.status == CaptureStatus.recording) return;
    emit(state.copyWith(status: CaptureStatus.recording, waveform: List.filled(64, 0.05), recordingSeconds: 0));

    _recordTicker?.cancel();
    _recordTicker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (isClosed) return;
      emit(state.copyWith(recordingSeconds: state.recordingSeconds + 1));
    });

    _waveTimer?.cancel();
    _waveTimer = Timer.periodic(const Duration(milliseconds: 120), (_) {
      if (isClosed) return;
      _sampleIdx++;
      final envelope = 0.35 + 0.45 * math.sin(_sampleIdx * 0.35).abs();
      final wave = List<double>.generate(64, (i) {
        final t = math.sin(_sampleIdx * 0.9 + i * 0.4);
        return (envelope * (0.6 + 0.4 * t.abs()) * (0.5 + 0.5 * _rnd.nextDouble())).clamp(0.03, 1);
      });
      emit(state.copyWith(waveform: wave));
    });
  }

  void stopRecording() {
    if (state.status != CaptureStatus.recording) return;
    _waveTimer?.cancel();
    _recordTicker?.cancel();
    final duration = state.recordingSeconds < 3 ? 12 : state.recordingSeconds;
    emit(state.copyWith(status: CaptureStatus.transcribing, transcribing: 'whisper.cpp · transkripsi on-device'));

    Future<void>.delayed(const Duration(seconds: 2), () {
      if (isClosed) return;
      final draft = _buildDraftFromVoice(duration);
      emit(state.copyWith(
        status: CaptureStatus.drafting,
        notes: [draft, ...state.notes],
        activeDraft: draft,
      ));
    });
  }

  void confirmStep(int index, bool confirmed) {
    final draft = state.activeDraft;
    if (draft == null) return;
    final steps = [
      for (var i = 0; i < draft.sopSteps.length; i++)
        i == index ? SopDraftStep(order: draft.sopSteps[i].order, title: draft.sopSteps[i].title, detail: draft.sopSteps[i].detail, confirmed: confirmed) : draft.sopSteps[i],
    ];
    final updated = _copyNote(draft, steps);
    final notes = [for (final n in state.notes) n.id == draft.id ? updated : n];
    emit(state.copyWith(notes: notes, activeDraft: updated));
  }

  void exportDraft() {
    final draft = state.activeDraft;
    if (draft == null) return;
    final exported = TacitNote(
      id: draft.id,
      title: draft.title,
      technician: draft.technician,
      line: draft.line,
      durationSeconds: draft.durationSeconds,
      recordedAt: draft.recordedAt,
      waveform: draft.waveform,
      transcribedText: draft.transcribedText,
      sopSteps: draft.sopSteps,
      status: SopDraftStatus.exported,
    );
    emit(state.copyWith(
      status: CaptureStatus.idle,
      activeDraft: null,
      notes: [for (final n in state.notes) n.id == draft.id ? exported : n],
    ));
  }

  TacitNote _buildDraftFromVoice(int seconds) {
    final base = TacitNote(
      id: 'note-${DateTime.now().microsecondsSinceEpoch}',
      title: 'Bersihkan filter hydraulic press (tanpa hentikan mesin)',
      technician: 'Eko Prasetyo',
      line: 'Line 2 - Pressing',
      durationSeconds: seconds,
      recordedAt: DateTime.now(),
      waveform: MockData.buildWaveform(64),
      transcribedText:
          'Filter hydraulic press bisa dibersihkan tanpa hentikan mesin kalau unit idle. '
          'Buka cover akses kanan, lepas 2 clamp, filter ditarik pelan ke atas. '
          'Blow pakai udara 4 bar dari dalam ke luar. Bersihkan return line dulu sebelum pasang ulang.',
      sopSteps: const [
        SopDraftStep(
          order: 1,
          title: 'Identifikasi mode idle',
          detail: 'Pastikan press dalam mode idle dan tekanan accumulator 0 bar.',
          confirmed: true,
        ),
        SopDraftStep(
          order: 2,
          title: 'Buka cover akses',
          detail: 'Buka cover kanan, lepas 2 clamp filter dengan tangan tanpa alat.',
          confirmed: false,
        ),
        SopDraftStep(
          order: 3,
          title: 'Blow & pasang ulang',
          detail: 'Blow dari dalam ke luar, bersihkan return line, pasang ulang dan cek kebocoran.',
          confirmed: false,
        ),
      ],
    );
    return base;
  }

  TacitNote _copyNote(TacitNote note, List<SopDraftStep> steps) {
    return TacitNote(
      id: note.id,
      title: note.title,
      technician: note.technician,
      line: note.line,
      durationSeconds: note.durationSeconds,
      recordedAt: note.recordedAt,
      waveform: note.waveform,
      transcribedText: note.transcribedText,
      sopSteps: steps,
      status: note.status,
    );
  }

  @override
  Future<void> close() {
    _waveTimer?.cancel();
    _recordTicker?.cancel();
    return super.close();
  }
}