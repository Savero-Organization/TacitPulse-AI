import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/models/worker_profile.dart';
import '../../core/theme/app_colors.dart';

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key, required this.onComplete});

  final VoidCallback onComplete;

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameCtrl = TextEditingController();
  final _nikCtrl = TextEditingController();
  String _selectedArea = WorkerProfile.workAreas.first;
  String _selectedShift = WorkerProfile.shifts.first;

  @override
  void dispose() {
    _nameCtrl.dispose();
    _nikCtrl.dispose();
    super.dispose();
  }

  String get _nodeName => WorkerProfile.generateNodeName(_nameCtrl.text, _selectedArea);

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    final profile = WorkerProfile(
      fullName: _nameCtrl.text.trim(),
      employeeId: _nikCtrl.text.trim(),
      workArea: _selectedArea,
      shift: _selectedShift,
      nodeName: _nodeName,
    );
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('onboarding_complete', true);
    await prefs.setString('worker_profile', profile.toJson());
    widget.onComplete();
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
              const SizedBox(height: 24),
              const Icon(Icons.engineering_rounded, color: AppColors.industrialAmber, size: 56),
              const SizedBox(height: 16),
              const Text(
                'TacitPulse AI',
                textAlign: TextAlign.center,
                style: TextStyle(color: AppColors.textPrimary, fontSize: 26, fontWeight: FontWeight.w800, letterSpacing: 0.5),
              ),
              const SizedBox(height: 6),
              const Text(
                'Setup Profil Teknisi',
                textAlign: TextAlign.center,
                style: TextStyle(color: AppColors.textSecondary, fontSize: 14),
              ),
              const SizedBox(height: 32),

              _fieldLabel('NAMA LENGKAP'),
              TextFormField(
                controller: _nameCtrl,
                onChanged: (_) => setState(() {}),
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
              const SizedBox(height: 18),

              _fieldLabel('AREA / LINE KERJA'),
              DropdownButtonFormField<String>(
                initialValue: _selectedArea,
                dropdownColor: AppColors.deepCharcoal,
                style: const TextStyle(color: AppColors.textPrimary, fontSize: 14),
                decoration: const InputDecoration(),
                items: WorkerProfile.workAreas
                    .map((a) => DropdownMenuItem(value: a, child: Text(a)))
                    .toList(),
                onChanged: (v) => setState(() => _selectedArea = v!),
              ),
              const SizedBox(height: 18),

              _fieldLabel('SHIFT KERJA'),
              DropdownButtonFormField<String>(
                initialValue: _selectedShift,
                dropdownColor: AppColors.deepCharcoal,
                style: const TextStyle(color: AppColors.textPrimary, fontSize: 14),
                decoration: const InputDecoration(),
                items: WorkerProfile.shifts
                    .map((s) => DropdownMenuItem(value: s, child: Text(s)))
                    .toList(),
                onChanged: (v) => setState(() => _selectedShift = v!),
              ),
              const SizedBox(height: 24),

              _fieldLabel('NAMA PERANGKAT NODE'),
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: AppColors.deepCharcoal,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppColors.industrialAmber.withValues(alpha: 0.5)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.devices_other_rounded, color: AppColors.industrialAmber, size: 20),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        _nodeName.isEmpty ? 'TEK-XXX-NAMA' : _nodeName,
                        style: TextStyle(
                          color: _nodeName.isEmpty ? AppColors.textMuted : AppColors.textPrimary,
                          fontFamily: 'monospace',
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 32),

              FilledButton.icon(
                onPressed: _save,
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.industrialAmber,
                  foregroundColor: AppColors.slateDark,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                ),
                icon: const Icon(Icons.hub_rounded),
                label: const Text('Create Local Mesh Hub', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: _save,
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.cyanAccent,
                  side: const BorderSide(color: AppColors.cyanAccent),
                  padding: const EdgeInsets.symmetric(vertical: 16),
                ),
                icon: const Icon(Icons.qr_code_scanner_rounded),
                label: const Text('Join Existing Mesh via QR Code', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
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
