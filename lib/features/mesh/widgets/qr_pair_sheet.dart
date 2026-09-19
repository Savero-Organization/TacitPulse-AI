import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/theme/app_colors.dart';

/// Bottom sheet untuk instant pairing: tampilkan QR identity node
/// sendiri, atau pindai QR rekan kerja.
class QrPairSheet extends StatelessWidget {
  const QrPairSheet({super.key, required this.nodeName, required this.qrPayload});

  final String nodeName;
  final String qrPayload;

  static Future<void> show(BuildContext context, {required String nodeName, required String qrPayload}) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => QrPairSheet(nodeName: nodeName, qrPayload: qrPayload),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.all(16),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.deepCharcoal,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppColors.surfaceBorder),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Row(
            children: [
              Icon(Icons.qr_code_2_rounded, color: AppColors.cyanAccent, size: 20),
              SizedBox(width: 8),
              Expanded(
                child: Text('Instant Pairing QR',
                    style: TextStyle(color: AppColors.textPrimary, fontSize: 16, fontWeight: FontWeight.w700)),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(nodeName,
              style: const TextStyle(color: AppColors.industrialAmber, fontFamily: 'monospace', fontSize: 13, fontWeight: FontWeight.w700)),
          const SizedBox(height: 20),

          // QR code placeholder (render nyata saat backend P2P siap).
          Container(
            width: 180,
            height: 180,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
            ),
            child: CustomPaint(
              painter: _QrPlaceholderPainter(payload: qrPayload),
            ),
          ),
          const SizedBox(height: 20),

          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => Clipboard.setData(ClipboardData(text: qrPayload)),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.textSecondary,
                    side: const BorderSide(color: AppColors.surfaceBorder),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  icon: const Icon(Icons.copy_rounded, size: 18),
                  label: const Text('Salin Payload', style: TextStyle(fontWeight: FontWeight.w600)),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton.icon(
                  onPressed: () => Navigator.pop(context),
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.industrialAmber,
                    foregroundColor: AppColors.slateDark,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  icon: const Icon(Icons.wifi_tethering_rounded, size: 18),
                  label: const Text('Scan QR Rekan', style: TextStyle(fontWeight: FontWeight.w700)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          const Text(
            'Pastikan kedua perangkat dalam radius Wi-Fi / hotspot P2P yang sama.',
            textAlign: TextAlign.center,
            style: TextStyle(color: AppColors.textMuted, fontSize: 11),
          ),
        ],
      ),
    );
  }
}

/// Placeholder QR visual (deterministik, ringan) sebelum library QR siap.
class _QrPlaceholderPainter extends CustomPainter {
  const _QrPlaceholderPainter({required this.payload});

  final String payload;

  @override
  void paint(Canvas canvas, Size size) {
    final cell = size.width / 21;
    final rnd = _FakeRandom(payload.length * 2654435761 % 0xFFFFFFFF);
    final paint = Paint()..color = const Color(0xFF0F172A);

    bool on(int row, int col) {
      // Finder patterns 3 persegi di sudut.
      final inFinder = (row < 7 && col < 7) || (row < 7 && col >= 14) || (row >= 14 && col < 7);
      if (inFinder) {
        final r = row < 7 ? row : row - 14;
        final c = col < 7 ? col : col - 14;
        final rr = row < 7 && col < 7 ? row - 1 : (row >= 14 && col < 7 ? row - 14 - 1 : row - 1);
        final cc = col < 7 && row < 7 ? col - 1 : (col >= 14 ? col - 14 - 1 : col - 1);
        if (r == 0 || r == 6 || c == 0 || c == 6) return true;
        if ((r >= 2 && r <= 4) && (c >= 2 && c <= 4)) return true;
        return rr >= 0 && rr <= 4 && cc >= 0 && cc <= 4 && r >= 1 && r <= 5 && c >= 1 && c <= 5;
      }
      return rnd.nextDouble() > 0.55;
    }

    for (var row = 0; row < 21; row++) {
      for (var col = 0; col < 21; col++) {
        if (on(row, col)) {
          canvas.drawRect(Rect.fromLTWH(col * cell, row * cell, cell, cell), paint);
        }
      }
    }
  }

  @override
  bool shouldRepaint(covariant _QrPlaceholderPainter oldDelegate) => oldDelegate.payload != payload;
}

class _FakeRandom {
  _FakeRandom(this.seed);
  int seed;
  int _next() {
    seed = (seed * 1664525 + 1013904223) & 0xFFFFFFFF;
    return seed;
  }

  double nextDouble() => _next() / 0xFFFFFFFF;
}