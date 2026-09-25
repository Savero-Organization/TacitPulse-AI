import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tacit_pulse_ai/features/chat/widgets/bounding_box_overlay.dart';

void main() {
  group('mapNormalizedBboxToPageRect', () {
    test('maps normalized box ke pixel rect halaman', () {
      const page = Size(800, 1000);
      final rect = mapNormalizedBboxToPageRect(
        const Rect.fromLTWH(0.25, 0.5, 0.5, 0.25),
        page,
      );
      expect(rect, const Rect.fromLTWH(200, 500, 400, 250));
    });

    test('box full-page menutupi seluruh halaman', () {
      final rect = mapNormalizedBboxToPageRect(
        const Rect.fromLTWH(0, 0, 1, 1),
        const Size(612, 792),
      );
      expect(rect, const Rect.fromLTWH(0, 0, 612, 792));
    });

    test('clamp sisi yang melewati tepi halaman (0..1)', () {
      final rect = mapNormalizedBboxToPageRect(
        const Rect.fromLTWH(-0.2, 0.9, 0.5, 0.5),
        const Size(100, 100),
      );
      // left/top/right/bottom di-clip dulu ke 0..1 lalu diskalakan.
      expect(rect, const Rect.fromLTRB(0, 90, 30, 100));
    });

    test('aspek rasio halaman berbeda tetap proporsional per sumbu', () {
      const page = Size(500, 200);
      final rect = mapNormalizedBboxToPageRect(
        const Rect.fromLTWH(0.1, 0.2, 0.2, 0.4),
        page,
      );
      expect(rect.left, closeTo(50, 1e-9));
      expect(rect.top, closeTo(40, 1e-9));
      expect(rect.width, closeTo(100, 1e-9));
      expect(rect.height, closeTo(80, 1e-9));
    });
  });
}
