// ModelDownloadService — service unduhan model global yang "tahan latar
// belakang": bukan milik satu widget/sheet, jadi user bisa pindah layar dan
// mengerjakan hal lain sementara unduhan tetap berjalan di dalam app.
//
// Desain (dipilih: in-app background — bukan foreground service OS):
//   - Download dimiliki service singleton, progress tersedia via
//     `ChangeNotifier` → UI mana pun (status bar global, picker sheet)
//     bisa menampilkan & mengontrolnya.
//   - `pause()`/`cancel()` via checkpoint kooperatif di `downloadModel`
//     (header Range + `.tmp` parsial) → resume dilanjutkan dari byte
//     terakhir (setara `wget -c`).
//   - Saat OS menyuspend app (mobile): [onAppBackgrounded] mengubah fase ke
//     paused; [onAppForegrounded] resume otomatis.
//   - Data pending dipersist ke SharedPreferences → setelah app di-kill,
//     [restorePending] menghidupkan kembali status "paused" dengan byte
//     tersimpan, siap di-resume.
//   - Per-OS izin/entitlement dijelaskan oleh [PlatformDownloadSupport].

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState, WidgetsBindingObserver;
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../utils/model_loader.dart';
import 'platform_download_support.dart';

/// Fase siklus unduhan.
enum DownloadPhase { idle, downloading, paused, completed, failed }

/// Snapshot progres unduhan yang disiarkan ke UI.
@immutable
class DownloadProgress {
  const DownloadProgress({
    this.phase = DownloadPhase.idle,
    this.fileName,
    this.bytesDownloaded = 0,
    this.totalBytes = 0,
    this.speedBytesPerSecond = 0,
    this.errorMessage,
    this.resultPath,
    this.startedAt,
  });

  final DownloadPhase phase;
  final String? fileName;
  final int bytesDownloaded;
  final int totalBytes;
  final double speedBytesPerSecond;
  final String? errorMessage;
  final String? resultPath;
  final DateTime? startedAt;

  /// Fraksi 0..1; 0 bila total tidak diketahui.
  double get fraction {
    if (totalBytes <= 0) return 0;
    return (bytesDownloaded / totalBytes).clamp(0.0, 1.0);
  }

  bool get isActive =>
      phase == DownloadPhase.downloading || phase == DownloadPhase.paused;

  DownloadProgress copyWith({
    DownloadPhase? phase,
    String? fileName,
    int? bytesDownloaded,
    int? totalBytes,
    double? speedBytesPerSecond,
    String? errorMessage,
    String? resultPath,
    DateTime? startedAt,
  }) {
    return DownloadProgress(
      phase: phase ?? this.phase,
      fileName: fileName ?? this.fileName,
      bytesDownloaded: bytesDownloaded ?? this.bytesDownloaded,
      totalBytes: totalBytes ?? this.totalBytes,
      speedBytesPerSecond: speedBytesPerSecond ?? this.speedBytesPerSecond,
      errorMessage: errorMessage ?? this.errorMessage,
      resultPath: resultPath ?? this.resultPath,
      startedAt: startedAt ?? this.startedAt,
    );
  }
}

/// Service unduhan global (global progress bar di AppShell + picker sheet).
class ModelDownloadService extends ChangeNotifier {
  ModelDownloadService._();

  /// Instance app-wide (dipakai UI).
  static final ModelDownloadService instance = ModelDownloadService._();

  /// Instance mandiri untuk unit test — bukan singleton.
  @visibleForTesting
  factory ModelDownloadService.create() => ModelDownloadService._();

  static const pendingFileKey = 'pending_download_file';
  static const pendingUrlKey = 'pending_download_url';

  DownloadProgress _progress = const DownloadProgress();
  DownloadProgress get progress => _progress;

  String? _activeUrl;
  String? _activeFileName;
  http.Client? _activeClient;
  bool _cancelRequested = false;

  /// `true` → penghentian karena pause/background (pertahankan pending);
  /// `false` → penghentian karena cancel murni (buang pending).
  bool _keepPending = false;

  DateTime? _startedAt;
  Stopwatch? _progressWatch;
  int _prevBytes = 0;
  int _lastTotal = 0;
  double _speed = 0;

  bool get isDownloading => _progress.phase == DownloadPhase.downloading;
  bool get isPaused => _progress.phase == DownloadPhase.paused;

  void _emit(DownloadProgress next) {
    _progress = next;
    notifyListeners();
  }

  /// Mulai (atau lanjutkan) unduhan. Aman dipanggil dari mana saja; bila
  /// sudah sedang mengunduh, diabaikan. Pindah screen TIDAK menghentikan
  /// unduhan — service hidup di luar widget.
  Future<void> startDownload({
    required String url,
    required String fileName,
    http.Client? client,
  }) async {
    if (isDownloading) return;

    _activeUrl = url;
    _activeFileName = fileName;
    _activeClient = client;
    _cancelRequested = false;
    _keepPending = false;
    _startedAt = DateTime.now();
    _speed = 0;
    _lastTotal = 0;
    _progressWatch?.stop();
    _prevBytes = 0;

    _emit(DownloadProgress(
      phase: DownloadPhase.downloading,
      fileName: fileName,
      startedAt: _startedAt,
    ));
    await _persistPending(fileName, url);

    final path = await ModelManager.downloadModel(
      url: url,
      fileName: fileName,
      client: client,
      onProgress: _onProgress,
      shouldCancel: () => _cancelRequested,
    );

    if (_cancelRequested) {
      _cancelRequested = false;
      if (_keepPending) {
        _keepPending = false;
        // Tetap berjalan sebagai "paused" dengan byte tersimpan (resume OK).
        _emit(DownloadProgress(
          phase: DownloadPhase.paused,
          fileName: fileName,
          bytesDownloaded: await _tmpBytes(fileName),
          totalBytes: _lastTotal,
          startedAt: _startedAt,
        ));
      } else {
        await _clearPending();
        _emit(const DownloadProgress());
      }
      return;
    }

    if (path != null) {
      await _clearPending();
      _emit(DownloadProgress(
        phase: DownloadPhase.completed,
        fileName: fileName,
        bytesDownloaded: _lastTotal > 0 ? _lastTotal : await _destBytes(path),
        totalBytes: _lastTotal,
        resultPath: path,
        startedAt: _startedAt,
      ));
    } else {
      // Gagal / interupsi jaringan — `.tmp` tetap ada untuk resume manual.
      _emit(DownloadProgress(
        phase: DownloadPhase.failed,
        fileName: fileName,
        bytesDownloaded: await _tmpBytes(fileName),
        totalBytes: _lastTotal,
        errorMessage: 'Unduh gagal / interupsi jaringan. '
            'Bisa dicoba lagi — byte tersimpan akan dilanjutkan.',
        startedAt: _startedAt,
      ));
    }
  }

  void _onProgress(int done, int total) {
    if (total > 0) _lastTotal = total;
    final watch = _progressWatch ??= Stopwatch()..start();
    final elapsedSec = watch.elapsedMilliseconds / 1000.0;
    final delta = done - _prevBytes;
    if (elapsedSec >= 0.4 && delta >= 0) {
      _speed = delta / elapsedSec;
      _progressWatch = Stopwatch()..start();
      _prevBytes = done;
    } else if (delta < 0) {
      _prevBytes = done;
    }
    _emit(DownloadProgress(
      phase: DownloadPhase.downloading,
      fileName: _activeFileName,
      bytesDownloaded: done,
      totalBytes: total > 0 ? total : 0,
      speedBytesPerSecond: _speed,
      startedAt: _startedAt,
    ));
  }

  /// Jeda kooperatif: unduhan berhenti di checkpoint berikutnya, `.tmp`
  /// dipertahankan, state jadi [DownloadPhase.paused] → [resume] lanjut
  /// dari byte tersimpan.
  void pause() {
    if (!isDownloading) return;
    _keepPending = true;
    _cancelRequested = true;
  }

  /// App di-background oleh OS (mobile): pause otomatis agar byte aman;
  /// [onAppForegrounded] akan resume.
  void onAppBackgrounded() {
    pause();
  }

  /// Lanjutkan unduhan yang ter-pause (resume dari byte tersimpan) — juga
  /// berlaku untuk fase [DownloadPhase.failed] (retry): `.tmp` parsial yang
  /// tersisa dipakai sebagai titik lanjut (wget -c); bila validator sudah
  /// menghapusnya, unduhan mulai fresh.
  Future<void> resume() async {
    final canResume =
        isPaused || _progress.phase == DownloadPhase.failed;
    if (!canResume) return;
    final url = _activeUrl;
    final name = _activeFileName;
    if (url == null || name == null) return;
    // Pakai klien yang sama dengan sesi awal (penting di unit test; untuk
    // pemakaian nyata `null` → klien HTTP default baru per attempt).
    await startDownload(url: url, fileName: name, client: _activeClient);
  }

  /// Aplikasi kembali ke foreground: resume unduhan yang ter-pause.
  Future<void> onAppForegrounded() async {
    if (isPaused) await resume();
  }

  /// Batalkan: buang status pending (`.tmp` parsial tetap boleh tersisa di
  /// cache — folder cache akan lenyap saat unduhan berikutnya sukses).
  void cancel() {
    if (isDownloading) {
      _keepPending = false;
      _cancelRequested = true;
      return;
    }
    if (isPaused) {
      _clearPending();
      _emit(const DownloadProgress());
    }
  }

  /// Abaikan status selesai (tutup status bar) tanpa menghapus model.
  void dismiss() {
    if (isDownloading) return;
    if (_progress.phase == DownloadPhase.completed ||
        _progress.phase == DownloadPhase.failed) {
      _clearPending();
      _emit(const DownloadProgress());
    }
  }

  /// Pulihkan unduhan yang terhenti oleh kill app / restart: baca pending
  /// dari SharedPreferences + byte `.tmp` tersimpan → status [DownloadPhase.paused].
  /// Dipanggil sekali saat app start (UKURAN sampai boleh ketika idle).
  Future<void> restorePending() async {
    if (_progress.phase != DownloadPhase.idle) return;
    final prefs = await SharedPreferences.getInstance();
    final file = prefs.getString(pendingFileKey);
    final url = prefs.getString(pendingUrlKey);
    if (file == null || file.isEmpty || url == null || url.isEmpty) return;
    _activeUrl = url;
    _activeFileName = file;
    _emit(DownloadProgress(
      phase: DownloadPhase.paused,
      fileName: file,
      bytesDownloaded: await _tmpBytes(file),
      startedAt: DateTime.now(),
    ));
  }

  Future<void> _persistPending(String fileName, String url) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(pendingFileKey, fileName);
    await prefs.setString(pendingUrlKey, url);
  }

  Future<void> _clearPending() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(pendingFileKey);
    await prefs.remove(pendingUrlKey);
  }

  Future<int> _tmpBytes(String fileName) async {
    try {
      final cache = await ModelManager.downloadCacheDir();
      final f = File(p.join(cache.path, '$fileName.tmp'));
      return await f.exists() ? await f.length() : 0;
    } catch (_) {
      return 0;
    }
  }

  Future<int> _destBytes(String path) async {
    try {
      final f = File(path);
      return await f.exists() ? await f.length() : 0;
    } catch (_) {
      return 0;
    }
  }

  /// Truth: kemampuan latar belakang platform berjalan (untuk UI/footer).
  PlatformDownloadSupport get platformSupport =>
      PlatformDownloadSupport.ofCurrentPlatform();
}

/// Observer lifecycle app (didaftarkan di entrypoint) yang mengubah
/// [ModelDownloadService] jadi background-aware:
///   - Android/iOS (suspend benar-benar mematikan runtime Dart): app
///     di-minimize → pause otomatis; kembali → resume dari byte tersimpan.
///   - Desktop (Linux/macOS/Windows): minimize TIDAK menyuspend engine,
///     jadi unduhan terus berjalan tanpa di-pause.
class ModelDownloadLifecycleObserver with WidgetsBindingObserver {
  ModelDownloadLifecycleObserver(this.service);

  final ModelDownloadService service;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Hanya OS yang benar-benar menyuspend runtime yang perlu pause/resume
    // otomatis — di desktop minimize tetap aman untuk terus mengunduh.
    final suspendPauses = service.platformSupport.autoPauseResumeOnSuspend;
    if (!suspendPauses) return;

    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
        service.onAppBackgrounded();
        break;
      case AppLifecycleState.resumed:
        service.onAppForegrounded();
        break;
      case AppLifecycleState.inactive:
      case AppLifecycleState.detached:
        break;
    }
  }
}