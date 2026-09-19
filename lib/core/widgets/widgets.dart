import 'package:flutter/material.dart';

import '../theme/app_colors.dart';

/// Judul seksi dengan aksen industrial kecil (garis amber).
class SectionHeader extends StatelessWidget {
  const SectionHeader({super.key, required this.title, this.trailing});

  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          Container(width: 3, height: 14, color: AppColors.industrialAmber),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              title.toUpperCase(),
              style: const TextStyle(
                color: AppColors.textSecondary,
                fontSize: 12,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.1,
              ),
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

/// Kartu statistik grid (2 kolom) bergaya HMI industrial.
class MetricTile extends StatelessWidget {
  const MetricTile({
    super.key,
    required this.icon,
    required this.label,
    required this.value,
    this.valueColor = AppColors.textPrimary,
    this.iconColor = AppColors.cyanAccent,
  });

  final IconData icon;
  final String label;
  final String value;
  final Color valueColor;
  final Color iconColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.deepCharcoal,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.surfaceBorder),
      ),
      child: Row(
        children: [
          Icon(icon, color: iconColor, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label.toUpperCase(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: AppColors.textMuted, fontSize: 10, fontWeight: FontWeight.w600, letterSpacing: 0.6),
                ),
                const SizedBox(height: 3),
                Text(value, style: TextStyle(color: valueColor, fontSize: 16, fontWeight: FontWeight.w700)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Indikator status berdenyut (dot) untuk node / streaming.
class PulseDot extends StatelessWidget {
  const PulseDot({super.key, required this.color, this.size = 9});

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(color: color.withValues(alpha: 0.6), blurRadius: 6, spreadRadius: 1),
        ],
      ),
    );
  }
}

/// Label chip kecil untuk badge (Full/Light Node, SYNcing, dst).
class BadgeChip extends StatelessWidget {
  const BadgeChip({super.key, required this.label, required this.color, required this.light});

  final String label;
  final Color color;
  final Color light;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Text(
        label,
        style: TextStyle(color: light, fontSize: 10, fontWeight: FontWeight.w700, letterSpacing: 0.5),
      ),
    );
  }
}

/// Gaya teks monospace untuk nilai telemetri/status.
abstract final class MonoStyles {
  static const TextStyle value = TextStyle(
    color: AppColors.textPrimary,
    fontSize: 13,
    fontWeight: FontWeight.w600,
    fontFamily: 'monospace',
  );

  static const TextStyle small = TextStyle(
    color: AppColors.textMuted,
    fontSize: 11,
    fontFamily: 'monospace',
  );
}