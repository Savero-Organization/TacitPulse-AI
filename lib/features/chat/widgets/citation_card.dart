import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/models/citation.dart';
import 'citation_thumbnail.dart';

/// Kartu Source Citation untuk menampilkan referensi SOP / PDF
/// lengkap dengan bounding box region pada halaman.
class CitationCard extends StatelessWidget {
  const CitationCard({super.key, required this.citation, this.onTap});

  final SourceCitation citation;

  /// Dipanggil saat kartu diketuk (buka penampil PDF di halaman kutipan).
  final VoidCallback? onTap;

  Color get _typeColor => switch (citation.type) {
        CitationType.sop => AppColors.industrialAmber,
        CitationType.pdf => AppColors.cyanAccent,
        CitationType.worklog => AppColors.success,
        CitationType.machine => AppColors.warning,
      };

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppColors.slateMuted.withValues(alpha: 0.35),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.surfaceBorder),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            CitationThumbnail(box: citation.boundingBox, color: _typeColor),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      _Badge(text: citation.type.badge, color: _typeColor),
                      const SizedBox(width: 6),
                      Text('Hal. ${citation.page}',
                          style: const TextStyle(
                            color: AppColors.textMuted,
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                            fontFamily: 'monospace',
                          )),
                      const Spacer(),
                      Text('${(citation.score * 100).toStringAsFixed(0)}%',
                          style: TextStyle(color: _typeColor, fontSize: 12, fontWeight: FontWeight.w700, fontFamily: 'monospace')),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    citation.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: AppColors.textPrimary, fontSize: 13, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '"${citation.snippet}"',
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: AppColors.textSecondary, fontSize: 12, height: 1.35),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: TextStyle(color: color, fontSize: 9, fontWeight: FontWeight.w800, letterSpacing: 0.5),
      ),
    );
  }
}