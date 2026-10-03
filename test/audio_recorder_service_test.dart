import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:record/record.dart';
import 'package:tacit_pulse_ai/core/audio/audio_recorder_service.dart';

/// Fake yang merekam pemanggilan — tidak menyentuh plugin native.
class _FakeRecorderHandle implements AudioRecorderHandle {
  bool permission = true;
  bool started = false;
  bool stopped = false;
  RecordConfig? lastConfig;
  String? lastPath;
  String? stopResult;
  final StreamController<RecordState> stateController =
      StreamController<RecordState>.broadcast();
  final StreamController<Amplitude> ampController =
      StreamController<Amplitude>.broadcast();

  @override
  Future<bool> hasPermission() async => permission;

  @override
  Future<void> start(RecordConfig config, {required String path}) async {
    started = true;
    lastConfig = config;
    lastPath = path;
  }

  @override
  Future<String?> stop() async {
    stopped = true;
    return stopResult ?? lastPath;
  }

  @override
  Future<void> cancel() async {}

  @override
  Stream<RecordState> get onStateChanged => stateController.stream;

  @override
  Stream<Amplitude> onAmplitudeChanged(Duration interval) =>
      ampController.stream;

  @override
  Future<void> dispose() async {}
}

void main() {
  late Directory tempRoot;
  late _FakeRecorderHandle fake;
  late AudioRecorderService service;

  setUp(() {
    tempRoot = Directory.systemTemp.createTempSync('tacit_rec_');
    fake = _FakeRecorderHandle();
    service = AudioRecorderService(
      recorder: fake,
      tempDirResolver: () async => tempRoot,
    );
  });

  tearDown(() {
    tempRoot.deleteSync(recursive: true);
  });

  test('startRecording memakai config whisper (wav/16k/mono)', () async {
    await service.startRecording();
    expect(fake.started, isTrue);
    expect(fake.lastConfig?.encoder, AudioEncoder.wav);
    expect(fake.lastConfig?.sampleRate, 16000);
    expect(fake.lastConfig?.numChannels, 1);
    expect(fake.lastPath, endsWith('.wav'));
    expect(fake.lastPath, startsWith(tempRoot.path));
  });

  test('startRecording tanpa izin → StateError, plugin tidak dipanggil',
      () async {
    fake.permission = false;
    await expectLater(service.startRecording(), throwsStateError);
    expect(fake.started, isFalse);
  });

  test('customPath dipakai apa adanya', () async {
    await service.startRecording(customPath: '${tempRoot.path}/custom.wav');
    expect(fake.lastPath, '${tempRoot.path}/custom.wav');
  });

  test('stopRecording mengembalikan path dan membersihkan state', () async {
    await service.startRecording();
    final path = await service.stopRecording();
    expect(path, fake.lastPath);
    expect(service.currentPath, isNull);
  });

  test('cancelRecording menghapus file rekaman', () async {
    final file = File('${tempRoot.path}/cancel.wav')..writeAsBytesSync([1, 2]);
    fake.stopResult = file.path;
    await service.startRecording(customPath: file.path);
    fake.stopResult = file.path;
    await service.cancelRecording();
    expect(file.existsSync(), isFalse);
    expect(service.currentPath, isNull);
  });

  test('onStateChanged diteruskan dari handle', () async {
    final seen = <RecordState>[];
    final sub = service.onStateChanged.listen(seen.add);
    fake.stateController.add(RecordState.record);
    fake.stateController.add(RecordState.stop);
    await Future<void>.delayed(Duration.zero);
    await sub.cancel();
    expect(seen, [RecordState.record, RecordState.stop]);
  });

  test('onAmplitudeChanged diteruskan dari handle', () async {
    final seen = <Amplitude>[];
    final sub = service.onAmplitudeChanged.listen(seen.add);
    fake.ampController.add(Amplitude(current: -10, max: 0));
    await Future<void>.delayed(Duration.zero);
    await sub.cancel();
    expect(seen.single.current, -10);
  });

  test('dispose meneruskan ke handle', () async {
    var disposed = false;
    final s = AudioRecorderService(
      recorder: _DisposingRecorder(() => disposed = true),
      tempDirResolver: () async => tempRoot,
    );
    await s.dispose();
    expect(disposed, isTrue);
  });
}

class _DisposingRecorder extends _FakeRecorderHandle {
  _DisposingRecorder(this._onDispose);
  final void Function() _onDispose;

  @override
  Future<void> dispose() async => _onDispose();
}
