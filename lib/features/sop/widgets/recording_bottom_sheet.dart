// recording_bottom_sheet.dart — lembar bawah modal untuk perekaman suara
// teknisi sebelum diproses Whisper + Qwen (GABUT-55).

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:record/record.dart';

import '../../../core/audio/audio_recorder_service.dart';
import '../../../core/theme/app_colors.dart';

/// Sheet modal perekaman suara dengan durasi berjalan dan waveform realtime.
class RecordingBottomSheet extends StatefulWidget {
  const RecordingBottomSheet({
    super.key,
    required this.recorderService,
    required this.onProcess,
    this.onCancel,
  });

  /// Service perekaman (di-inject supaya bisa di-mock di widget test).
  final AudioRecorderService recorderService;

  /// Dipanggil setelah Stop & Process dengan path file .wav hasil
  /// (null bila service tidak menghasilkan path).
  final void Function(String? wavPath) onProcess;

  /// Dipanggil setelah Cancel (opsional).
  final VoidCallback? onCancel;

  static Future<void> show(
    BuildContext context, {
    required AudioRecorderService recorderService,
    required void Function(String? wavPath) onProcess,
    VoidCallback? onCancel,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      isDismissible: false,
      enableDrag: false,
      backgroundColor: AppColors.deepCharcoal,
      builder: (_) => RecordingBottomSheet(
        recorderService: recorderService,
        onProcess: onProcess,
        onCancel: onCancel,
      ),
    );
  }

  @override
  State<RecordingBottomSheet> createState() => _RecordingBottomSheetState();
}

class _RecordingBottomSheetState extends State<RecordingBottomSheet> {
  Timer? _ticker;
  Duration _elapsed = Duration.zero;
  final List<double> _waveform = <double>[];
  StreamSubscription<Amplitude>? _ampSub;
  bool _starting = true;
  String? _error;

  /// Dibatalkan sebelum startRecording selesai → jangan lanjut merekam.
  bool _cancelRequested = false;
  bool _recordingStarted = false;
  bool _finished = false;

  @override
  void initState() {
    super.initState();
    _ampSub = widget.recorderService.onAmplitudeChanged.listen((amp) {
      // Amplitude current dalam dBFS (-160..0); normalisasi ke 0..1.
      final normalized = ((amp.current + 60) / 60).clamp(0.0, 1.0);
      if (!mounted) return;
      setState(() {
        _waveform.add(normalized);
        if (_waveform.length > 64) _waveform.removeAt(0);
      });
    });
    _start();
  }

  Future<void> _start() async {
    try {
      await widget.recorderService.startRecording();
      if (_cancelRequested) {
        // Cancel datang saat start masih berjalan: batalkan rekaman yang
        // baru terbentuk supaya native tidak merekam tanpa UI.
        await widget.recorderService.cancelRecording();
        return;
      }
      _recordingStarted = true;
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted) return;
        setState(() => _elapsed += const Duration(seconds: 1));
      });
      if (mounted) setState(() => _starting = false);
    } catch (e) {
      if (mounted) {
        setState(() {
          _starting = false;
          _error = '$e';
        });
      }
    }
  }

  String _formatDuration(Duration d) {
    final mm = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final ss = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$mm:$ss';
  }

  Future<void> _stopAndProcess() async {
    _ticker?.cancel();
    _finished = true;
    try {
      final path = await widget.recorderService.stopRecording();
      if (!mounted) return;
      Navigator.of(context).pop();
      widget.onProcess(path);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    }
  }

  Future<void> _cancel() async {
    _ticker?.cancel();
    _cancelRequested = true;
    _finished = true;
    try {
      await widget.recorderService.cancelRecording();
    } catch (_) {
      // abaikan — lanjut menutup sheet
    }
    if (!mounted) return;
    Navigator.of(context).pop();
    widget.onCancel?.call();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _ampSub?.cancel();
    // Jaminan tidak ada rekaman native yang tertinggal bila sheet
    // di-dispose di jalur yang tidak memanggil stop/cancel (mis. regresi
    // dismissible: true atau exception di antara startRecording dan ticker).
    if (_recordingStarted && !_finished) {
      unawaited(widget.recorderService.cancelRecording());
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        20, 16, 20, MediaQuery.viewInsetsOf(context).bottom + 24,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Container(
              width: 42,
              height: 4,
              decoration: BoxDecoration(
                color: AppColors.slateMuted,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 18),
          Text(
            _error == null ? 'Merekam Instruksi Suara' : 'Gagal Merekam',
            style: const TextStyle(
              color: AppColors.textPrimary,
              fontSize: 18,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            _error ?? 'Bicara jelas ke mikrofon perangkat.',
            style: const TextStyle(color: AppColors.textSecondary),
          ),
          const SizedBox(height: 20),
          Center(
            child: Text(
              _formatDuration(_elapsed),
              key: const Key('recording_duration'),
              style: const TextStyle(
                color: AppColors.industrialAmber,
                fontSize: 40,
                fontWeight: FontWeight.w800,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 96,
            child: CustomPaint(
              key: const Key('recording_waveform'),
              painter: _WavePainter(
                samples: _waveform.isEmpty ? const [0.05] : List.of(_waveform),
                color: AppColors.cyanAccent,
                active: _error == null,
              ),
              size: const Size(double.infinity, 96),
            ),
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  key: const Key('recording_cancel'),
                  onPressed: _cancel,
                  child: const Text('Cancel'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  key: const Key('recording_stop_process'),
                  onPressed: _error == null && !_starting
                      ? _stopAndProcess
                      : null,
                  child: const Text('Stop & Process'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _WavePainter extends CustomPainter {
  _WavePainter({required this.samples, required this.color, required this.active});

  final List<double> samples;
  final Color color;
  final bool active;

  @override
  void paint(Canvas canvas, Size size) {
    if (samples.isEmpty) return;
    final barWidth = (size.width / samples.length) * 0.55;
    final gap = (size.width / samples.length) * 0.45;
    final midY = size.height / 2;
    final strokePaint = Paint()
      ..color = active ? color : AppColors.slateMuted
      ..strokeWidth = barWidth.clamp(1.5, 6.0).toDouble()
      ..strokeCap = StrokeCap.round;
    for (var i = 0; i < samples.length; i++) {
      final x = i * (barWidth + gap) + gap / 2;
      final amp = size.height * 0.42 * samples[i].clamp(0.03, 1.0);
      canvas.drawLine(Offset(x, midY - amp), Offset(x, midY + amp), strokePaint);
    }
  }

  @override
  bool shouldRepaint(covariant _WavePainter oldDelegate) =>
      oldDelegate.samples != samples ||
      oldDelegate.color != color ||
      oldDelegate.active != active;
}
