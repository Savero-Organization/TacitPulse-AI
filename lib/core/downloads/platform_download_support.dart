// PlatformDownloadSupport — matriks kemampuan & persyaratan izin per-OS
// untuk unduhan model "di latar belakang".
//
// Filosofi: unduhan model TIDAK butuh izin storage di platform mana pun
// karena ditulis ke storage privat app (`ModelPaths.appDataRoot` / system
// temp cache). Yang harus diperhatikan per-OS hanya jaringan & daemon/service:
//   - Android : INTERNET wajib dideklarasi di manifest (release); izin
//     storage TIDAK diperlukan. `POST_NOTIFICATIONS` (Android 13+, opsional)
//     diperlukan hanya bila nanti memasang progress notification.
//   - iOS     : HTTPS ke CDN aman (ATS bersih, tidak perlu NSAllowsArbitraryLoads);
//     tidak ada izin storage/network tambahan untuk unduhan in-app.
//   - macOS   : App Sandbox WAJIB entitlement `com.apple.security.network.client`
//     untuk request HTTP keluar — tanpa ini unduhan gagal (SocketException).
//   - Windows : tidak ada izin tambahan; unduhan berlanjut selama proses hidup.
//   - Linux   : tidak ada izin tambahan (semua distro); unduhan berlanjut
//     selama proses hidup.
//
// "Background" yang didukung di sini adalah in-app background: download
// terus berjalan saat user pindah layar/tab/panel. Saat OS menyuspend app
// (mobile), service otomatis pause lalu resume dari byte yang tersimpan
// (`.tmp` + header Range) ketika app kembali ke foreground.

import 'dart:io';

import 'package:flutter/foundation.dart';

/// Ringkasan kemampuan & persyaratan izin latar belakang satu platform.
@immutable
class PlatformDownloadSupport {
  const PlatformDownloadSupport({
    required this.inAppBackground,
    required this.autoPauseResumeOnSuspend,
    required this.requiresNetworkPermission,
    required this.requiresNotificationPermission,
    required this.requiredEntitlements,
    required this.summary,
  });

  /// Unduhan berlanjut saat user tetap menggunakan app (pindah layar/tab).
  final bool inAppBackground;

  /// Saat OS menyuspend app (mobile di-minimize), service pause lalu resume
  /// otomatis dari byte tersimpan ketika app kembali.
  final bool autoPauseResumeOnSuspend;

  /// Izin jaringan harus dideklarasi/di-resolve dulu (Android INTERNET dst.).
  final bool requiresNetworkPermission;

  /// Izin notifikasi runtime diperlukan bila ingin menampilkan progress
  /// notification (Android 13+). False hari ini — UI progress berbasis
  /// in-app status bar, bukan notifikasi sistem.
  final bool requiresNotificationPermission;

  /// Entitlement/izinkan manifest yang harus ada agar unduhan jalan.
  final List<String> requiredEntitlements;

  /// Deskripsi singkat (Indonesia) untuk UI.
  final String summary;

  /// Support untuk platform berjalan saat ini.
  static PlatformDownloadSupport ofCurrentPlatform() {
    if (!kIsWeb && Platform.isAndroid) {
      return const PlatformDownloadSupport(
        inAppBackground: true,
        autoPauseResumeOnSuspend: true,
        requiresNetworkPermission: true,
        requiresNotificationPermission: false,
        requiredEntitlements: ['android.permission.INTERNET'],
        summary: 'Android: unduhan berlanjut antar-layar, pause/resume otomatis '
            'saat minimisasi, dan berlanjut dari byte tersimpan.',
      );
    }
    if (!kIsWeb && Platform.isIOS) {
      return const PlatformDownloadSupport(
        inAppBackground: true,
        autoPauseResumeOnSuspend: true,
        requiresNetworkPermission: false,
        requiresNotificationPermission: false,
        requiredEntitlements: [],
        summary: 'iOS: unduhan in-app berlanjut antar-layar; saat app '
            'disuspend otomatis pause, lalu resume dari byte tersimpan.',
      );
    }
    if (!kIsWeb && Platform.isMacOS) {
      return const PlatformDownloadSupport(
        inAppBackground: true,
        autoPauseResumeOnSuspend: false,
        requiresNetworkPermission: false,
        requiresNotificationPermission: false,
        requiredEntitlements: ['com.apple.security.network.client'],
        summary: 'macOS: sandbox wajib entitlement network.client untuk HTTP '
            'keluar; unduhan berlanjut saat user pindah layar.',
      );
    }
    if (!kIsWeb && Platform.isWindows) {
      return const PlatformDownloadSupport(
        inAppBackground: true,
        autoPauseResumeOnSuspend: false,
        requiresNetworkPermission: false,
        requiresNotificationPermission: false,
        requiredEntitlements: [],
        summary: 'Windows: tanpa izin tambahan; unduhan berjalan selama app '
            'di buka.',
      );
    }
    // Linux (semua distro) + fallback.
    return const PlatformDownloadSupport(
      inAppBackground: true,
      autoPauseResumeOnSuspend: false,
      requiresNetworkPermission: false,
      requiresNotificationPermission: false,
      requiredEntitlements: [],
      summary: 'Linux: tanpa izin tambahan di semua distro; unduhan berlanjut '
          'saat user pindah layar / app di-minimize.',
    );
  }

  @override
  bool operator ==(Object other) =>
      other is PlatformDownloadSupport &&
      other.inAppBackground == inAppBackground &&
      other.autoPauseResumeOnSuspend == autoPauseResumeOnSuspend &&
      other.requiresNetworkPermission == requiresNetworkPermission &&
      other.requiresNotificationPermission == requiresNotificationPermission &&
      other.requiredEntitlements.length == requiredEntitlements.length &&
      other.summary == summary;

  @override
  int get hashCode => Object.hash(
        inAppBackground,
        autoPauseResumeOnSuspend,
        requiresNetworkPermission,
        requiredEntitlements.length,
        summary,
      );
}