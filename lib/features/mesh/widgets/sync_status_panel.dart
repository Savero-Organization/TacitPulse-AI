import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/widgets/widgets.dart';

/// Transfer P2P aktif di panel sinkronisasi.
class MeshTransfer {
  const MeshTransfer({
    required this.name,
    required this.detail,
    required this.progress,
  });

  final String name;
  final String detail;
  final double progress;
}

/// Panel status sinkronisasi: daftar transfer P2P dengan progress bar.
class SyncStatusPanel extends StatelessWidget {
  const SyncStatusPanel({super.key, required this.transfers});

  final List<MeshTransfer> transfers;

  static const List<Color> _accents = [
    AppColors.cyanAccent,
    AppColors.industrialAmber,
    AppColors.success,
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 14),
      decoration: const BoxDecoration(
        color: AppColors.deepCharcoal,
        border: Border(top: BorderSide(color: AppColors.surfaceBorder)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionHeader(title: 'Active Sync Status'),
          for (var i = 0; i < transfers.length; i++)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.swap_vert_circle_rounded,
                          color: _accents[i % _accents.length], size: 14),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          transfers[i].name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: AppColors.textPrimary,
                              fontSize: 12,
                              fontWeight: FontWeight.w600),
                        ),
                      ),
                      Text(transfers[i].detail,
                          style: const TextStyle(
                              color: AppColors.textMuted, fontSize: 10)),
                      const SizedBox(width: 10),
                      Text(
                        '${(transfers[i].progress * 100).clamp(0, 100).toInt()}%',
                        style: MonoStyles.small,
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: LinearProgressIndicator(
                      value: transfers[i].progress,
                      minHeight: 5,
                      backgroundColor: AppColors.slateMuted,
                      valueColor: const AlwaysStoppedAnimation(
                          AppColors.industrialAmber),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}