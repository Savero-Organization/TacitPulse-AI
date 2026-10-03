import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:record/record.dart';
import 'package:tacit_pulse_ai/core/audio/audio_recorder_service.dart';
import 'package:tacit_pulse_ai/features/sop/widgets/recording_bottom_sheet.dart';

class _FakeHandle implements AudioRecorderHandle {
  bool started = false;
  bool cancelled = false;
  String? startedPath;
  final StreamController<RecordState> stateC =
      StreamController<RecordState>.broadcast();
  final StreamController<Amplitude> ampC =
      StreamController<Amplitude>.broadcast();

  @override
  Future<bool> hasPermission() async => true;
  @override
  Future<void> start(RecordConfig config, {required String path}) async {
    started = true;
    startedPath = path;
  }
  @override
  Future<String?> stop() async => startedPath;
  @override
  Future<void> cancel() async => cancelled = true;
  @override
  Stream<RecordState> get onStateChanged => stateC.stream;
  @override
  Stream<Amplitude> onAmplitudeChanged(Duration interval) => ampC.stream;
  @override
  Future<void> dispose() async {}
}


void main() {
  late Directory tempRoot;
  late _FakeHandle fake;
  late AudioRecorderService service;

  setUp(() {
    tempRoot = Directory.systemTemp.createTempSync('tacit_recsheet_');
    fake = _FakeHandle();
    service = AudioRecorderService(
      recorder: fake,
      tempDirResolver: () async => tempRoot,
    );
  });

  tearDown(() {
    tempRoot.deleteSync(recursive: true);
  });

  Future<void> pumpSheet(WidgetTester tester,
      {void Function(String?)? onProcess, VoidCallback? onCancel}) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(builder: (context) {
          return ElevatedButton(
            onPressed: () => RecordingBottomSheet.show(
              context,
              recorderService: service,
              onProcess: onProcess ?? (_) {},
              onCancel: onCancel,
            ),
            child: const Text('open'),
          );
        }),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
  }

  testWidgets('durasi berjalan format MM:SS', (tester) async {
    await pumpSheet(tester);
    expect(find.byKey(const Key('recording_duration')), findsOneWidget);
    expect(find.text('00:00'), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('00:02'), findsOneWidget);
    await tester.pump(const Duration(seconds: 61));
    expect(find.text('01:03'), findsOneWidget);
  });

  testWidgets('waveform ter-render dan bereaksi ke amplitude', (tester) async {
    await pumpSheet(tester);
    expect(find.byKey(const Key('recording_waveform')), findsOneWidget);
    fake.ampC.add(Amplitude(current: -20, max: 0));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byKey(const Key('recording_waveform')), findsOneWidget);
  });

  testWidgets('Stop & Process menghentikan rekaman dan memanggil onProcess',
      (tester) async {
    String? processed;
    await pumpSheet(tester, onProcess: (path) => processed = path);
    expect(fake.started, isTrue);
    await tester.tap(find.byKey(const Key('recording_stop_process')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(processed, isNotNull);
    expect(processed, endsWith('.wav'));
  });

  testWidgets('Cancel membatalkan via service dan onCancel lampau',
      (tester) async {
    var cancelledCalled = false;
    await pumpSheet(tester, onCancel: () => cancelledCalled = true);
    await tester.tap(find.byKey(const Key('recording_cancel')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(cancelledCalled, isTrue);
  });
}
