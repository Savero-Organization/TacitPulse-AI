// radar_scan_widget.dart — visualisasi pemindaian peer (radar berputar).

import 'dart:math' show cos, sin;

import 'package:flutter/material.dart';

/// Widget animasi radar: cincin berputar + sweep saat [scanning] aktif.
class RadarScanWidget extends StatefulWidget {
  const RadarScanWidget({super.key, required this.scanning, this.size = 220});

  /// Bila true, animasi diulang (isAnimating == true); false → berhenti.
  final bool scanning;
  final double size;

  @override
  State<RadarScanWidget> createState() => RadarScanWidgetState();
}

class RadarScanWidgetState extends State<RadarScanWidget>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  /// Terlihat oleh test: true selagi animasi sedang berjalan.
  bool get isAnimating => _controller.isAnimating;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    );
    if (widget.scanning) {
      _controller.repeat();
    }
  }

  @override
  void didUpdateWidget(covariant RadarScanWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.scanning && !_controller.isAnimating) {
      _controller.repeat();
    } else if (!widget.scanning && _controller.isAnimating) {
      _controller.stop();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (_, _) => CustomPaint(
          painter: _RadarPainter(_controller.value),
          child: Center(
            child: Icon(Icons.radar,
                size: widget.size * 0.18,
                color: Theme.of(context).colorScheme.primary),
          ),
        ),
      ),
    );
  }
}

class _RadarPainter extends CustomPainter {
  _RadarPainter(this.t);

  final double t; // 0..1 per putaran

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2);
    final maxR = size.width / 2;
    final ring = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4
      ..color = Colors.teal.withValues(alpha: 0.45);
    for (var i = 1; i <= 3; i++) {
      canvas.drawCircle(c, maxR * i / 3, ring);
    }
    // Sweep wedge — berputar tiap 2 s.
    final sweep = Paint()
      ..style = PaintingStyle.fill
      ..color = Colors.teal.withValues(alpha: 0.18);
    final startAngle = -t * 2 * 3.14159265;
    canvas.drawArc(
      Rect.fromCircle(center: c, radius: maxR),
      startAngle,
      0.7,
      true,
      sweep,
    );
    final edge = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = Colors.teal;
    canvas.drawLine(
      c,
      Offset(c.dx + maxR * cos(startAngle), c.dy + maxR * sin(startAngle)),
      edge,
    );
  }

  @override
  bool shouldRepaint(covariant _RadarPainter old) => old.t != t;
}