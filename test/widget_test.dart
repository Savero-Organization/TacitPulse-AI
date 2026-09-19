import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:tacit_pulse_ai/main.dart';

void main() {
  testWidgets('Shows onboarding first time app opens', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const TacitPulseApp());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('Setup Profil Teknisi'), findsOneWidget);
    await tester.drag(find.byType(ListView), const Offset(0, -400));
    await tester.pump();
    expect(find.text('Create Local Mesh Hub'), findsWidgets);
    expect(find.text('Join Existing Mesh via QR Code'), findsWidgets);
  });

  testWidgets('TacitPulse app renders shell with AirDrop tab after onboarding',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({
      'onboarding_complete': true,
      'worker_profile':
          '{"fullName":"Eko Prasetyo","employeeId":"10234567","workArea":"Line 2 - Filling","shift":"Shift 1 (06:00 - 14:00)","nodeName":"TEK-LINE2-EKO","isFullNode":true}',
    });
    await tester.pumpWidget(const TacitPulseApp());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('AirDrop'), findsOneWidget);
    expect(find.text('Chat'), findsOneWidget);
    expect(find.text('Capture'), findsOneWidget);
    expect(find.text('Eko Prasetyo'), findsOneWidget);
  });
}