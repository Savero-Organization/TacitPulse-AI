import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'core/downloads/download_notification_service.dart';
import 'core/downloads/model_download_service.dart';
import 'core/rag/knowledge_ingest_service.dart';
import 'core/utils/model_loader.dart';
import 'core/theme/app_colors.dart';
import 'core/theme/app_theme.dart';
import 'features/auth/login_screen.dart';
import 'features/settings/model_settings_cubit.dart';
import 'features/auth/onboarding_screen.dart';
import 'features/shell/app_shell.dart';

Future<void> _initDownloadNotifications() async {
  try {
    await DownloadNotificationService.instance.init();
    DownloadNotificationService.instance.attach();
  } catch (_) {
    // Platform tanpa dukungan notifikasi lokal → unduhan tetap jalan in-app.
  }
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Unduhan model tetap "hidup" lintas-layout: pause/resume otomatis saat
  // app disuspend (mobile) + pulihkan unduhan yang terhenti oleh kill app.
  final lifecycle = ModelDownloadLifecycleObserver(
    ModelDownloadService.instance,
  );
  WidgetsBinding.instance.addObserver(lifecycle);
  ModelDownloadService.instance.restorePending();
  // Muat pilihan model tersimpan ke state sebelum model dimuat.
  unawaited(ModelSettingsCubit.instance.load());
  // Notifikasi sistem untuk progres unduhan model (menggantikan banner in-app).
  unawaited(_initDownloadNotifications());
  // Seed index vektor dokumen Case 1 sekali (background) — tidak memblokir UI.
  unawaited(KnowledgeIngestService().ensureSeeded());
  // Saat unduhan model embedding beres (di mana pun user berada), isi ulang
  // indeks dokumen supaya citations bisa pakai embedding baru.
  ModelDownloadService.instance.addListener(() {
    final p = ModelDownloadService.instance.progress;
    if (p.phase == DownloadPhase.completed &&
        p.fileName == ModelManager.embeddingModelName) {
      unawaited(KnowledgeIngestService().ensureSeeded());
    }
  });
  runApp(const TacitPulseApp());
}

class TacitPulseApp extends StatefulWidget {
  const TacitPulseApp({super.key});

  @override
  State<TacitPulseApp> createState() => _TacitPulseAppState();
}

class _TacitPulseAppState extends State<TacitPulseApp> {
  bool? _onboardingComplete;

  // Login per-sesi: selalu mulai dari false tiap app dibuka, jadi halaman
  // login muncul SETIAP waktu (onboarding tetap sekali seumur install).
  bool _loggedIn = false;

  VoidCallback? _refresh;

  @override
  void initState() {
    super.initState();
    _refresh = _checkOnboarding;
    _checkOnboarding();
  }

  Future<void> _checkOnboarding() async {
    final prefs = await SharedPreferences.getInstance();
    final done = prefs.getBool('onboarding_complete') ?? false;
    setState(() => _onboardingComplete = done);
  }

  @override
  Widget build(BuildContext context) {
    if (_onboardingComplete == null) {
      return MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.dark,
        home: const Scaffold(body: Center(child: CircularProgressIndicator(color: AppColors.industrialAmber))),
      );
    }

    // Urutan gerbang: onboarding (sekali — bikin profil) → login (SETIAP
    // app dibuka; sesi cuma hidup di memori) → app.
    return MaterialApp(
      title: 'TacitPulse AI',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark,
      home: !_onboardingComplete!
          ? OnboardingScreen(onComplete: _refresh!)
          : !_loggedIn
              ? LoginScreen(onLogin: () => setState(() => _loggedIn = true))
              : AppShell(onRefreshProfile: _refresh!),
    );
  }
}
