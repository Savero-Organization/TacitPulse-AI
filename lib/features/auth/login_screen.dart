import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/models/worker_profile.dart';
import '../../core/theme/app_colors.dart';

/// Halaman login — verifikasi NIK + nama terhadap profil tersimpan di
/// perangkat (`worker_profile`). Muncul SETIAP kali aplikasi dibuka
/// (sesi login tidak dipersist), dengan field auto-fill dari profil.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key, required this.onLogin});

  /// Dipanggil setelah verifikasi lolos.
  final VoidCallback onLogin;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameCtrl = TextEditingController();
  final _nikCtrl = TextEditingController();
  String? _error;
  bool _checking = false;

  @override
  void initState() {
    super.initState();
    _prefill();
  }

  /// Auto-fill dari profil tersimpan — user tinggal tekan Masuk,
  /// nggak perlu ketik ulang.
  Future<void> _prefill() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('worker_profile');
    if (raw == null || !mounted) return;
    final profile = WorkerProfile.fromJson(raw);
    setState(() {
      _nameCtrl.text = profile.fullName;
      _nikCtrl.text = profile.employeeId;
    });
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _nikCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _error = null;
      _checking = true;
    });

    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('worker_profile');
    final profile = raw == null ? null : WorkerProfile.fromJson(raw);

    // Cocokkan case-insensitive & trim — NIK/nama harus sama dengan yang
    // diisi saat onboarding.
    final nama = _nameCtrl.text.trim().toLowerCase();
    final nik = _nikCtrl.text.trim().toLowerCase();
    final ok = profile != null &&
        nama == profile.fullName.trim().toLowerCase() &&
        nik == profile.employeeId.trim().toLowerCase();

    if (!ok) {
      setState(() {
        _checking = false;
        _error = profile == null
            ? 'Profil belum dibuat. Selesaikan setup profil dulu.'
            : 'NIK atau nama tidak cocok dengan profil di perangkat ini.';
      });
      return;
    }

    widget.onLogin();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.slateDark,
      body: SafeArea(
        child: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
            children: [
              const SizedBox(height: 48),
              const Icon(Icons.login_rounded, color: AppColors.industrialAmber, size: 56),
              const SizedBox(height: 16),
              const Text(
                'TacitPulse AI',
                textAlign: TextAlign.center,
                style: TextStyle(color: AppColors.textPrimary, fontSize: 26, fontWeight: FontWeight.w800, letterSpacing: 0.5),
              ),
              const SizedBox(height: 6),
              const Text(
                'Masuk — verifikasi dengan profil di perangkat ini',
                textAlign: TextAlign.center,
                style: TextStyle(color: AppColors.textSecondary, fontSize: 14),
              ),
              const SizedBox(height: 32),

              _fieldLabel('NAMA LENGKAP'),
              TextFormField(
                controller: _nameCtrl,
                style: const TextStyle(color: AppColors.textPrimary),
                decoration: const InputDecoration(hintText: 'Contoh: Eko Prasetyo'),
                validator: (v) => (v == null || v.trim().isEmpty) ? 'Wajib diisi' : null,
              ),
              const SizedBox(height: 18),

              _fieldLabel('NIK / ID KARYAWAN'),
              TextFormField(
                controller: _nikCtrl,
                keyboardType: TextInputType.number,
                style: const TextStyle(color: AppColors.textPrimary),
                decoration: const InputDecoration(hintText: 'Contoh: 10234567'),
                validator: (v) => (v == null || v.trim().isEmpty) ? 'Wajib diisi' : null,
              ),
              const SizedBox(height: 24),

              if (_error != null) ...[
                Text(
                  _error!,
                  style: const TextStyle(color: AppColors.danger, fontSize: 13),
                ),
                const SizedBox(height: 12),
              ],

              FilledButton.icon(
                onPressed: _checking ? null : _submit,
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.industrialAmber,
                  foregroundColor: AppColors.slateDark,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                ),
                icon: _checking
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.slateDark),
                      )
                    : const Icon(Icons.login_rounded),
                label: Text(
                  _checking ? 'Memeriksa...' : 'Masuk',
                  style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
                ),
              ),
              const SizedBox(height: 32),
            ],
          ),
        ),
      ),
    );
  }

  static Widget _fieldLabel(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        text,
        style: const TextStyle(
          color: AppColors.textMuted,
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.8,
        ),
      ),
    );
  }
}
