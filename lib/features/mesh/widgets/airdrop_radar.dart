import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/models/mesh_node.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/widgets/widgets.dart';

/// AirDrop Radar View: mendeteksi teknisi/stasiun di sekeliling
/// dalam radius Wi-Fi / P2P. Pusat = perangkat kita.
class AirdropRadar extends StatefulWidget {
  const AirdropRadar({super.key, required this.nodes, required this.onNodeTap});

  final List<MeshNode> nodes;
  final ValueChanged<MeshNode> onNodeTap;

  @override
  State<AirdropRadar> createState() => _AirdropRadarState();
}

class _AirdropRadarState extends State<AirdropRadar> with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: const Duration(seconds: 4))
      ..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 1,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          return LayoutBuilder(
            builder: (context, constraints) {
              return Center(
                child: SizedBox(
                  width: constraints.maxWidth,
                  height: constraints.maxWidth,
                  child: CustomPaint(
                    painter: _RadarPainter(nodes: widget.nodes, sweep: _controller.value),
                    child: GestureDetector(
                      onTapUp: (d) {
                        final hit = _hitTest(context, d.localPosition);
                        if (hit != null) widget.onNodeTap(hit);
                      },
                      child: const Center(
                        child: Stack(
                          clipBehavior: Clip.none,
                          children: [
                            // Dot = satu-satunya child non-positioned, jadi
                            // ukuran stack = dot → Center menaruhnya TEPAT
                            // di pusat radar (tanpa penyeimbang).
                            PulseDot(color: AppColors.industrialAmber, size: 14),
                            // Label diposisikan absolut di bawah dot:
                            // top = 14 (tinggi dot) + 6 (gap).
                            Positioned(
                              top: 20,
                              left: -40,
                              right: -40,
                              child: Text('ANDA',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    color: AppColors.textSecondary,
                                    fontSize: 10,
                                    fontWeight: FontWeight.w700,
                                    letterSpacing: 1.2,
                                  )),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }

  MeshNode? _hitTest(BuildContext context, Offset local) {
    final size = context.size ?? Size.zero;
    final center = Offset(size.width / 2, size.height / 2);
    final radius = math.min(size.width, size.height) * 0.42;
    final peers = widget.nodes.where((n) => n.id != 'node-00').toList();
    for (var i = 0; i < peers.length; i++) {
      final angle = -math.pi / 2 + (2 * math.pi * i) / peers.length;
      final pos = center + Offset(math.cos(angle), math.sin(angle)) * radius;
      if ((local - pos).distance < 22) return peers[i];
    }
    return null;
  }
}

class _RadarPainter extends CustomPainter {
  _RadarPainter({required this.nodes, required this.sweep});

  final List<MeshNode> nodes;
  final double sweep;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = math.min(size.width, size.height) * 0.42;

    // Grid radar.
    final gridPaint = Paint()
      ..color = AppColors.surfaceBorder.withValues(alpha: 0.5)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    for (var r = 0.33; r <= 1.0; r += 0.33) {
      canvas.drawCircle(center, radius * r, gridPaint);
    }
    // Cross axis.
    canvas.drawLine(center - Offset(radius, 0), center + Offset(radius, 0), gridPaint);
    canvas.drawLine(center - Offset(0, radius), center + Offset(0, radius), gridPaint);

    final sweepAngle = 2 * math.pi * sweep - math.pi / 2;

    // Trail di belakang garis: 16 irisan pai memudar (ekor 120°) — murni
    // geometri drawArc dari `sweepAngle` yang sama dengan garis, jadi selalu
    // ikut muter; bentuk di sweep=1 identik dengan sweep=0 → wrap seamless.
    const kTrailSlices = 16;
    const kTrailSpan = 2 * math.pi / 3;
    const kTrailStep = kTrailSpan / kTrailSlices;
    for (var i = 0; i < kTrailSlices; i++) {
      final fade = i / (kTrailSlices - 1); // 0 = ujung ekor, 1 = dekat garis
      final trailPaint = Paint()
        ..color = AppColors.cyanAccent.withValues(alpha: 0.24 * fade)
        ..style = PaintingStyle.fill;
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        sweepAngle - kTrailSpan + i * kTrailStep,
        kTrailStep,
        true,
        trailPaint,
      );
    }

    // Garis sweep: dari pusat ke tepi, muter penuh 360° tiap siklus.
    final sweepPaint = Paint()
      ..color = AppColors.cyanAccent.withValues(alpha: 0.55)
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    final tip = center + Offset(math.cos(sweepAngle), math.sin(sweepAngle)) * radius;
    canvas.drawLine(center, tip, sweepPaint);

    // Node lokal (self).
    canvas.drawCircle(center, 10, Paint()..color = AppColors.deepCharcoal);
    canvas.drawCircle(
      center,
      10,
      Paint()
        ..color = AppColors.industrialAmber
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5,
    );

    // Peers.
    final peers = nodes.where((n) => n.id != 'node-00').toList();
    for (var i = 0; i < peers.length; i++) {
      final p = peers[i];
      final angle = -math.pi / 2 + (2 * math.pi * i) / peers.length;
      final pos = center + Offset(math.cos(angle), math.sin(angle)) * radius;

      final color = switch (p.status) {
        NodeStatus.online => AppColors.success,
        NodeStatus.syncing => AppColors.industrialAmber,
        NodeStatus.offline => AppColors.textMuted,
      };

      // Blip + pulse ring.
      canvas.drawCircle(
        pos,
        8,
        Paint()
          ..color = color.withValues(alpha: 0.2 + 0.15 * ((sweep + i * 0.13) % 1))
          ..style = PaintingStyle.fill,
      );
      canvas.drawCircle(
        pos,
        8,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
      canvas.drawCircle(
        pos,
        8 + 6 * ((sweep + i * 0.13) % 1),
        Paint()
          ..color = color.withValues(alpha: 0.25 * (1 - (sweep + i * 0.13) % 1))
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _RadarPainter oldDelegate) {
    return oldDelegate.nodes != nodes || oldDelegate.sweep != sweep;
  }
}