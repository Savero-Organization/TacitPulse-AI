// ModelDownloadStatusBar — strip status unduhan model GLOBAL yang muncul di
// bagian atas shell (AppShell) selama unduhan latar belakang berjalan.
//
// Karena bind ke [ModelDownloadService] (ChangeNotifier global), bar ini
// tetap hidup walau user pergi ke tab mana pun — itulah esensi "unduh di
// latar belakang, user kerjakan hal lain". Menyediakan pause/resume/cancel
// langsung dari bar.

import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../downloads/model_download_service.dart';

/// Strip tipis (inline, bukan overlay) yang tampil hanya ketika ada unduhan
/// aktif / ter-pause / baru selesai / gagal.
class ModelDownloadStatusBar extends StatelessWidget {
  const ModelDownloadStatusBar({super.key, this.service});

  /// Service unduhan yang dipantau; default singletons [ModelDownloadService.instance].
  final ModelDownloadService? service;

  ModelDownloadService get _model => service ?? ModelDownloadService.instance;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _model,
      builder: (context, _) {
        final p = _model.progress;
        if (!p.isActive &&
            p.phase != DownloadPhase.completed &&
            p.phase != DownloadPhase.failed) {
          return const SizedBox.shrink();
        }
        return Container(
          width: double.infinity,
          color: AppColors.deepCharcoal,
          padding: const EdgeInsets.fromLTRB(14, 8, 10, 8),
          child: Row(
            children: [
              Icon(_phaseIcon(p.phase),
                  color: _phaseColor(p.phase), size: 20),
              const SizedBox(width: 10),
              Expanded(child: _buildInfo(context, p)),
              _buildActions(p),
            ],
          ),
        );
      },
    );
  }

  IconData _phaseIcon(DownloadPhase phase) => switch (phase) {
        DownloadPhase.downloading => Icons.cloud_download_rounded,
        DownloadPhase.paused => Icons.pause_circle_outline_rounded,
        DownloadPhase.completed => Icons.check_circle_rounded,
        DownloadPhase.failed => Icons.error_outline_rounded,
        DownloadPhase.idle => Icons.cloud_outlined,
      };

  Color _phaseColor(DownloadPhase phase) => switch (phase) {
        DownloadPhase.downloading => AppColors.cyanAccent,
        DownloadPhase.paused => AppColors.warning,
        DownloadPhase.completed => AppColors.success,
        DownloadPhase.failed => AppColors.danger,
        DownloadPhase.idle => AppColors.textMuted,
      };

  Widget _buildInfo(BuildContext context, DownloadProgress p) {
    String detail;
    switch (p.phase) {
      case DownloadPhase.downloading:
        detail = _formatBytes(p.bytesDownloaded, p.totalBytes) +
            (p.speedBytesPerSecond > 0
                ? ' · ${_speedText(p.speedBytesPerSecond)}'
                : '');
        break;
      case DownloadPhase.paused:
        detail = 'Dijeda — ${_formatBytes(p.bytesDownloaded, p.totalBytes)} '
            'tersimpan, lanjut kapan saja';
        break;
      case DownloadPhase.completed:
        detail = 'Selesai ✓ — model siap dimuat';
        break;
      case DownloadPhase.failed:
        detail = p.errorMessage ?? 'Unduh gagal — coba lagi';
        break;
      case DownloadPhase.idle:
        detail = '';
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          p.fileName ?? 'model.gguf',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: AppColors.textPrimary,
            fontSize: 12,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 4),
        if (p.phase == DownloadPhase.downloading || p.phase == DownloadPhase.paused)
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: p.fraction,
              minHeight: 4,
              backgroundColor: AppColors.slateMuted,
              valueColor: AlwaysStoppedAnimation(
                p.phase == DownloadPhase.downloading
                    ? AppColors.industrialAmber
                    : AppColors.warning,
              ),
            ),
          ),
        const SizedBox(height: 4),
        Text(
          detail,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: p.phase == DownloadPhase.failed
                ? AppColors.danger
                : AppColors.textMuted,
            fontSize: 11,
            fontFamily: 'monospace',
          ),
        ),
      ],
    );
  }

  Widget _buildActions(DownloadProgress p) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (p.phase == DownloadPhase.downloading) ...[
          _iconButton(
            tooltip: 'Jeda unduhan',
            icon: Icons.pause_rounded,
            color: AppColors.warning,
            onTap: _model.pause,
          ),
        ] else if (p.phase == DownloadPhase.paused) ...[
          _iconButton(
            tooltip: 'Lanjutkan unduhan',
            icon: Icons.play_arrow_rounded,
            color: AppColors.success,
            onTap: _model.resume,
          ),
        ],
        if (p.phase == DownloadPhase.failed)
          _iconButton(
            tooltip: 'Coba lagi (resume)',
            icon: Icons.refresh_rounded,
            color: AppColors.cyanAccent,
            onTap: _model.resume,
          ),
        if (p.isActive || p.phase == DownloadPhase.completed)
          _iconButton(
            tooltip: p.phase == DownloadPhase.completed
                ? 'Tutup pemberitahuan'
                : 'Batalkan unduhan',
            icon: Icons.close_rounded,
            color: AppColors.textMuted,
            onTap: p.phase == DownloadPhase.completed
                ? _model.dismiss
                : _model.cancel,
          ),
      ],
    );
  }

  Widget _iconButton({
    required String tooltip,
    required IconData icon,
    required Color color,
    required VoidCallback onTap,
  }) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onTap,
      icon: Icon(icon, color: color, size: 20),
      visualDensity: VisualDensity.compact,
      padding: const EdgeInsets.all(6),
    );
  }

  String _formatBytes(int done, int total) {
    const mb = 1024 * 1024;
    final doneMb = (done / mb).toStringAsFixed(1);
    if (total <= 0) return '$doneMb MB';
    return '$doneMb MB / ${(total / mb).toStringAsFixed(1)} MB';
  }

  String _speedText(double bytesPerSecond) {
    final mb = bytesPerSecond / (1024 * 1024);
    return '${mb.toStringAsFixed(1)} MB/s';
  }
}