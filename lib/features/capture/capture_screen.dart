import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/models/tacit_note.dart';
import '../../core/theme/app_colors.dart';
import '../../core/widgets/profile_app_bar_action.dart';
import '../../core/widgets/widgets.dart';
import 'cubit/capture_cubit.dart';
import 'sop_draft_sheet.dart';
import 'widgets/waveform_visualizer.dart';

/// Tacit Capture & SOP Generator.
class CaptureScreen extends StatelessWidget {
  const CaptureScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (ctx) => CaptureCubit(),
      child: const _CaptureView(),
    );
  }
}

class _CaptureView extends StatelessWidget {
  const _CaptureView();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Tacit Capture'),
        actions: const [ProfileAppBarAction()],
      ),
      body: BlocBuilder<CaptureCubit, CaptureState>(
        builder: (context, state) {
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              const SectionHeader(title: 'Perekaman Voice Note'),
              _RecorderPanel(state: state),
              const SizedBox(height: 18),
              const SectionHeader(title: 'Riwayat Voice Note'),
              _NotesList(state: state),
              const SizedBox(height: 24),
            ],
          );
        },
      ),
    );
  }
}

class _RecorderPanel extends StatelessWidget {
  const _RecorderPanel({required this.state});

  final CaptureState state;

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<CaptureCubit>();
    final isRecording = state.status == CaptureStatus.recording;
    final isTranscribing = state.status == CaptureStatus.transcribing;
    final isDrafting = state.status == CaptureStatus.drafting;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.deepCharcoal,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.surfaceBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Status badge.
          Row(
            children: [
              PulseDot(
                color: isRecording
                    ? AppColors.danger
                    : isTranscribing
                        ? AppColors.warning
                        : isDrafting
                            ? AppColors.success
                            : AppColors.textMuted,
              ),
              const SizedBox(width: 6),
              Text(
                _statusText,
                style: TextStyle(
                  color: isRecording
                      ? AppColors.danger
                      : isTranscribing
                          ? AppColors.warning
                          : isDrafting
                              ? AppColors.success
                              : AppColors.textSecondary,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.8,
                ),
              ),
              if (isRecording) ...[
                const Spacer(),
                Text(
                  _time(state.recordingSeconds),
                  style: const TextStyle(color: AppColors.textPrimary, fontSize: 13, fontFamily: 'monospace'),
                ),
              ],
            ],
          ),
          const SizedBox(height: 14),

          // Waveform.
          if (isRecording || state.waveform.isNotEmpty)
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: AppColors.slateDark,
                borderRadius: BorderRadius.circular(10),
              ),
              child: WaveformVisualizer(
                samples: state.waveform,
                color: AppColors.cyanAccent,
                active: isRecording,
              ),
            )
          else
            Container(
              height: 80,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: AppColors.slateDark,
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Text(
                'Tekan tombol REKAM untuk memulai',
                style: TextStyle(color: AppColors.textMuted, fontSize: 13),
              ),
            ),

          const SizedBox(height: 16),

          // Action buttons.
          Row(
            children: [
              Expanded(
                child: isRecording
                    ? FilledButton.icon(
                        onPressed: () => cubit.stopRecording(),
                        style: FilledButton.styleFrom(
                          backgroundColor: AppColors.danger,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                        icon: const Icon(Icons.stop_rounded),
                        label: const Text('Stop Rekam', style: TextStyle(fontWeight: FontWeight.w700)),
                      )
                    : isDrafting && state.activeDraft != null
                        ? FilledButton.icon(
                            onPressed: () => SopDraftSheet.show(context, state.activeDraft!),
                            style: FilledButton.styleFrom(
                              backgroundColor: AppColors.industrialAmber,
                              foregroundColor: AppColors.slateDark,
                              padding: const EdgeInsets.symmetric(vertical: 14),
                            ),
                            icon: const Icon(Icons.description_outlined),
                            label: const Text('Lihat Draft SOP', style: TextStyle(fontWeight: FontWeight.w700)),
                          )
                        : FilledButton.icon(
                            onPressed: cubit.startRecording,
                            style: FilledButton.styleFrom(
                              backgroundColor: AppColors.cyanAccent,
                              foregroundColor: AppColors.slateDark,
                              padding: const EdgeInsets.symmetric(vertical: 14),
                            ),
                            icon: const Icon(Icons.mic_rounded),
                            label: const Text('Rekam Voice Note', style: TextStyle(fontWeight: FontWeight.w700)),
                          ),
              ),
            ],
          ),
          if (isDrafting && state.activeDraft != null)
            const Padding(
              padding: EdgeInsets.only(top: 10),
              child: Row(
                children: [
                  PulseDot(color: AppColors.success),
                  SizedBox(width: 6),
                  Text(
                    'whisper.cpp selesai transkripsi · Draft SOP siap dikonfirmasi.',
                    style: TextStyle(color: AppColors.textSecondary, fontSize: 12),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  String get _statusText => switch (state.status) {
        CaptureStatus.recording => 'RECORDING',
        CaptureStatus.transcribing => 'TRANSCRIBING',
        CaptureStatus.drafting => 'DRAFT SIAP',
        CaptureStatus.idle => 'IDLE',
      };

  String _time(int seconds) => '${(seconds ~/ 60).toString().padLeft(2, '0')}:${(seconds % 60).toString().padLeft(2, '0')}';
}

class _NotesList extends StatelessWidget {
  const _NotesList({required this.state});

  final CaptureState state;

  @override
  Widget build(BuildContext context) {
    if (state.notes.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(24),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: AppColors.deepCharcoal,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.surfaceBorder),
        ),
        child: const Text(
          'Belum ada voice note.',
          style: TextStyle(color: AppColors.textMuted, fontSize: 13),
        ),
      );
    }

    return Column(
      children: [
        for (var i = 0; i < state.notes.length; i++) ...[
          _NoteTile(
            note: state.notes[i],
            onTap: state.notes[i].sopSteps.isNotEmpty
                ? () => SopDraftSheet.show(context, state.notes[i])
                : null,
          ),
          if (i < state.notes.length - 1) const SizedBox(height: 8),
        ],
      ],
    );
  }
}

class _NoteTile extends StatelessWidget {
  const _NoteTile({required this.note, required this.onTap});

  final TacitNote note;
  final VoidCallback? onTap;

  Color get _statusColor => switch (note.status) {
        SopDraftStatus.exported => AppColors.success,
        SopDraftStatus.ready => AppColors.cyanAccent,
        SopDraftStatus.drafting => AppColors.industrialAmber,
      };

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.deepCharcoal,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.surfaceBorder),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Waveform preview.
            SizedBox(
              width: 48,
              height: 48,
              child: WaveformVisualizer(samples: note.waveform, color: AppColors.cyanAccent, active: false),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    note.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: AppColors.textPrimary, fontSize: 13, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${note.technician} · ${note.line}',
                    style: const TextStyle(color: AppColors.textMuted, fontSize: 11),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    '${note.durationSeconds}s · ${note.sopSteps.length} langkah',
                    style: TextStyle(color: _statusColor, fontSize: 11, fontWeight: FontWeight.w600, fontFamily: 'monospace'),
                  ),
                ],
              ),
            ),
            BadgeChip(
              label: note.status == SopDraftStatus.exported ? 'EXPORTED' : note.status == SopDraftStatus.ready ? 'READY' : 'DRAFT',
              color: _statusColor,
              light: _statusColor,
            ),
          ],
        ),
      ),
    );
  }
}