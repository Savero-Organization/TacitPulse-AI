import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/models/tacit_note.dart';
import '../../core/theme/app_colors.dart';
import '../../core/widgets/widgets.dart';
import 'cubit/capture_cubit.dart';

/// Sheet konfirmasi cepat: konversi voice note menjadi draft SOP
/// terstruktur (langkah demi langkah).
class SopDraftSheet extends StatelessWidget {
  const SopDraftSheet({super.key, required this.note});

  final TacitNote note;

  static Future<void> show(BuildContext context, TacitNote note) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.deepCharcoal,
      builder: (_) => SopDraftSheet(note: note),
    );
  }

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<CaptureCubit, CaptureState>(
      builder: (context, state) {
        final current = state.activeDraft ?? note;
        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.92,
          maxChildSize: 0.98,
          minChildSize: 0.6,
          builder: (context, scrollController) {
            return ListView(
              controller: scrollController,
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
              children: [
                Center(
                  child: Container(
                    width: 42,
                    height: 4,
                    decoration: BoxDecoration(
                      color: AppColors.slateMuted,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 18),
                Row(
                  children: [
                    const Icon(Icons.description_outlined, color: AppColors.industrialAmber),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Draft SOP dari Voice Note',
                        style: const TextStyle(color: AppColors.textPrimary, fontSize: 18, fontWeight: FontWeight.w700),
                      ),
                    ),
                    InkWell(
                      onTap: () => Navigator.of(context).pop(),
                      child: const Icon(Icons.close_rounded, color: AppColors.textSecondary),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(current.title,
                    style: const TextStyle(color: AppColors.cyanAccent, fontSize: 13, fontWeight: FontWeight.w600)),
                const SizedBox(height: 14),
                _meta('TEKNISI', current.technician),
                _meta('LINE', current.line),
                _meta('DURASI', '${current.durationSeconds} detik'),
                const SizedBox(height: 16),
                const SectionHeader(title: 'Transkripsi (whisper.cpp)'),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppColors.slateDark,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: AppColors.surfaceBorder),
                  ),
                  child: Text(
                    current.transcribedText,
                    style: const TextStyle(color: AppColors.textSecondary, fontSize: 13, height: 1.5),
                  ),
                ),
                const SizedBox(height: 18),
                const SectionHeader(title: 'Langkah SOP Terstruktur'),
                for (final step in current.sopSteps) _StepTile(step: step),
                const SizedBox(height: 20),
                BlocBuilder<CaptureCubit, CaptureState>(
                  builder: (context, state) {
                    final ready = current.sopSteps.isNotEmpty && !current.sopSteps.any((s) => !s.confirmed);
                    return FilledButton.icon(
                      onPressed: ready ? () => context.read<CaptureCubit>().exportDraft() : null,
                      style: FilledButton.styleFrom(
                        backgroundColor: AppColors.industrialAmber,
                        foregroundColor: AppColors.slateDark,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        disabledBackgroundColor: AppColors.slateMuted,
                      ),
                      icon: const Icon(Icons.assignment_turned_in_outlined),
                      label: const Text('Simpan sebagai SOP', style: TextStyle(fontWeight: FontWeight.w700)),
                    );
                  },
                ),
                if (current.status == SopDraftStatus.exported)
                  const Padding(
                    padding: EdgeInsets.only(top: 12),
                    child: Row(
                      children: [
                        PulseDot(color: AppColors.success),
                        SizedBox(width: 8),
                        Text('Draft tersimpan ke Knowledge Store (sqlite).',
                            style: TextStyle(color: AppColors.textSecondary, fontSize: 12)),
                      ],
                    ),
                  ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _meta(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          SizedBox(
            width: 72,
            child: Text(label, style: const TextStyle(color: AppColors.textMuted, fontSize: 11, fontWeight: FontWeight.w600)),
          ),
          Text(value, style: const TextStyle(color: AppColors.textPrimary, fontSize: 12, fontFamily: 'monospace')),
        ],
      ),
    );
  }
}

class _StepTile extends StatelessWidget {
  const _StepTile({required this.step});

  final SopDraftStep step;

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<CaptureCubit, CaptureState>(
      builder: (context, state) {
        final matching = state.activeDraft?.sopSteps.where((s) => s.order == step.order) ?? const <SopDraftStep>[];
        final confirmed = matching.isNotEmpty ? matching.first.confirmed : step.confirmed;
        final imgIdx = state.activeDraft?.sopSteps.indexWhere((s) => s.order == step.order) ?? -1;
        return Container(
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: AppColors.slateMuted.withValues(alpha: 0.3),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: confirmed ? AppColors.success.withValues(alpha: 0.5) : AppColors.surfaceBorder),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 24,
                height: 24,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: confirmed ? AppColors.success.withValues(alpha: 0.18) : AppColors.slateDark,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: confirmed ? AppColors.success : AppColors.slateMuted),
                ),
                child: Text('${step.order}',
                    style: TextStyle(
                      color: confirmed ? AppColors.success : AppColors.textSecondary,
                      fontFamily: 'monospace',
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    )),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(step.title,
                        style: const TextStyle(color: AppColors.textPrimary, fontSize: 13, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 3),
                    Text(step.detail,
                        style: const TextStyle(color: AppColors.textSecondary, fontSize: 12, height: 1.4)),
                  ],
                ),
              ),
              Checkbox(
                value: confirmed,
                onChanged: imgIdx >= 0 ? (v) => context.read<CaptureCubit>().confirmStep(imgIdx, v ?? false) : null,
                activeColor: AppColors.success,
              ),
            ],
          ),
        );
      },
    );
  }
}