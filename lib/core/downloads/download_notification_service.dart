// DownloadNotificationService — menampilkan progres unduhan model sebagai
// NOTIFIKASI SISTEM lintas-platform (Android/iOS/Linux/macOS/Windows),
// menggantikan banner status di bagian atas AppShell.
//
// Service ini mendengarkan [ModelDownloadService] (ChangeNotifier global):
// setiap update progres → satu notifikasi persisten dipakai ulang (id tetap),
// menampilkan fase (downloading/paused/completed/failed) + persentase.

import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'model_download_service.dart';

class DownloadNotificationService {
  DownloadNotificationService._();
  static final DownloadNotificationService instance =
      DownloadNotificationService._();

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  static const _notificationId = 9001;
  static const _channelId = 'model_downloads_v2';
  static const _channelName = 'Model Downloads';
  static const _channelDesc = 'Progress unduhan model (GGUF) di background';

  bool _initialized = false;
  bool _attached = false;
  int _lastPercent = -1;
  DownloadPhase _lastPhase = DownloadPhase.idle;

  Future<void> init() async {
    if (_initialized) return;

    const android = AndroidInitializationSettings('ic_launcher');
    const darwin = DarwinInitializationSettings();

    const linux = LinuxInitializationSettings(
      defaultActionName: 'Buka TacitPulse AI',
    );

    const windows = WindowsInitializationSettings(
      appName: 'TacitPulse AI',
      appUserModelId: 'TacitPulse.TacitPulseAI.1',
      guid: '3f7d0f52-5f3d-4a1d-9a3f-2f7b8c1d6e10',
    );

    const settings = InitializationSettings(
      android: android,
      iOS: darwin,
      macOS: darwin,
      linux: linux,
      windows: windows,
    );

    await _plugin.initialize(settings: settings);

    await _requestPermissions();
    _initialized = true;
  }

  Future<void> _requestPermissions() async {
    try {
      final android = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      await android?.requestNotificationsPermission();

      await _plugin
          .resolvePlatformSpecificImplementation<
              IOSFlutterLocalNotificationsPlugin>()
          ?.requestPermissions(alert: true, badge: true, sound: true);

      await _plugin
          .resolvePlatformSpecificImplementation<
              MacOSFlutterLocalNotificationsPlugin>()
          ?.requestPermissions(alert: true, badge: true, sound: true);
    } catch (_) {
      // Platform tanpa permission API → abaikan.
    }
  }

  /// Mulai mendengarkan [service] dan memancarkan notifikasi progres.
  void attach({ModelDownloadService? service}) {
    if (_attached) return;
    _attached = true;
    final s = service ?? ModelDownloadService.instance;
    s.addListener(() => _onProgress(s.progress));
    _onProgress(s.progress);
  }

  Future<void> _onProgress(DownloadProgress p) async {
    if (!_initialized) return;

    final percent = (p.fraction * 100).round();
    final changed = percent != _lastPercent || p.phase != _lastPhase;
    if (!changed && p.phase == DownloadPhase.downloading) return;
    _lastPercent = percent;
    _lastPhase = p.phase;

    switch (p.phase) {
      case DownloadPhase.idle:
        await _plugin.cancel(id: _notificationId);
        break;
      case DownloadPhase.downloading:
        await _showProgress(p, percent, paused: false);
        break;
      case DownloadPhase.paused:
        await _showProgress(p, percent, paused: true);
        break;
      case DownloadPhase.completed:
        await _showTerminal(
          title: 'Download selesai',
          body: '${p.fileName ?? 'model'} siap dimuat',
          indeterminate: false,
        );
        break;
      case DownloadPhase.failed:
        await _showTerminal(
          title: 'Download gagal',
          body: p.errorMessage ?? '${p.fileName ?? 'model'} gagal diunduh',
          indeterminate: false,
        );
        break;
    }
  }

  Future<void> _showProgress(DownloadProgress p, int percent,
      {required bool paused}) async {
    final android = AndroidNotificationDetails(
      _channelId,
      _channelName,
      channelDescription: _channelDesc,
      importance: Importance.defaultImportance,
      priority: Priority.defaultPriority,
      showProgress: true,
      maxProgress: 100,
      progress: percent,
      onlyAlertOnce: true,
      ongoing: !paused,
      category: AndroidNotificationCategory.progress,
    );

    final linux = LinuxNotificationDetails(
      category: LinuxNotificationCategory.device,
      suppressSound: true,
    );

    final windows = WindowsNotificationDetails(
      bindings: {
        'title': p.fileName ?? 'Mengunduh model…',
        'body': paused ? 'Dijeda · $percent%' : 'Mengunduh · $percent%',
      },
      progressBars: [
        WindowsProgressBar(
          id: 'model_download',
          value: p.totalBytes > 0 ? p.fraction : 0,
          label: paused ? 'Dijeda · $percent%' : '$percent%',
          title: p.fileName ?? 'model',
          status: paused ? 'Paused' : 'Downloading',
        ),
      ],
    );

    final details = NotificationDetails(
      android: android,
      iOS: const DarwinNotificationDetails(
        presentAlert: true,
        presentBanner: true,
        presentSound: false,
      ),
      macOS: const DarwinNotificationDetails(
        presentAlert: true,
        presentBanner: true,
        presentSound: false,
      ),
      linux: linux,
      windows: windows,
    );

    final body = paused
        ? 'Dijeda · $percent% dari ${_fmt(p.totalBytes)}'
        : '$percent% · ${_fmtBytes(p.bytesDownloaded)} / ${_fmt(p.totalBytes)}'
            '${p.speedBytesPerSecond > 0 ? ' · ${_fmtBytes(p.speedBytesPerSecond.round())}/s' : ''}';

    await _plugin.show(
      id: _notificationId,
      title: p.fileName ?? 'Mengunduh model',
      body: body,
      notificationDetails: details,
    );
  }

  Future<void> _showTerminal({
    required String title,
    required String body,
    required bool indeterminate,
  }) async {
    final android = AndroidNotificationDetails(
      _channelId,
      _channelName,
      channelDescription: _channelDesc,
      importance: Importance.defaultImportance,
      priority: Priority.defaultPriority,
      showProgress: false,
      onlyAlertOnce: false,
      ongoing: false,
      category: AndroidNotificationCategory.progress,
    );
    final details = NotificationDetails(
      android: android,
      iOS: const DarwinNotificationDetails(presentSound: false),
      macOS: const DarwinNotificationDetails(presentSound: false),
      linux: const LinuxNotificationDetails(suppressSound: true),
      windows: WindowsNotificationDetails(
        bindings: {'title': title, 'body': body},
      ),
    );
    await _plugin.show(
      id: _notificationId,
      title: title,
      body: body,
      notificationDetails: details,
    );
  }

  String _fmt(int bytes) =>
      bytes <= 0 ? '…' : '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  String _fmtBytes(int bytes) =>
      '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}
