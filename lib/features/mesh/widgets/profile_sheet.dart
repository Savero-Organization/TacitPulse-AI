import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/models/worker_profile.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/widgets/widgets.dart';

class ProfileSheet extends StatefulWidget {
  const ProfileSheet({super.key, required this.profile, required this.onSaved});

  final WorkerProfile profile;
  final VoidCallback onSaved;

  static Future<void> show(BuildContext context, WorkerProfile profile, {VoidCallback? onSaved}) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => ProfileSheet(
        profile: profile,
        onSaved: onSaved ?? () {},
      ),
    );
  }

  @override
  State<ProfileSheet> createState() => _ProfileSheetState();
}

class _ProfileSheetState extends State<ProfileSheet> {
  late String _selectedArea;
  late String _selectedShift;
  late bool _isFullNode;
  late TextEditingController _nameCtrl;

  @override
  void initState() {
    super.initState();
    _selectedArea = widget.profile.workArea;
    _selectedShift = widget.profile.shift;
    _isFullNode = widget.profile.isFullNode;
    _nameCtrl = TextEditingController(text: widget.profile.fullName);
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final updated = widget.profile.copyWith(
      workArea: _selectedArea,
      shift: _selectedShift,
      isFullNode: _isFullNode,
      nodeName: WorkerProfile.generateNodeName(_nameCtrl.text, _selectedArea),
    );
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('worker_profile', updated.toJson());
    widget.onSaved();
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.75,
      minChildSize: 0.5,
      maxChildSize: 0.92,
      builder: (_, controller) => Container(
        decoration: const BoxDecoration(
          color: AppColors.deepCharcoal,
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: ListView(
          controller: controller,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: AppColors.slateMuted,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 20),
            const Row(
              children: [
                Icon(Icons.person_rounded, color: AppColors.industrialAmber, size: 22),
                SizedBox(width: 8),
                Text('Profil & Node Config', style: TextStyle(color: AppColors.textPrimary, fontSize: 18, fontWeight: FontWeight.w700)),
              ],
            ),
            const SizedBox(height: 20),

            _label('NAMA'),
            Text(widget.profile.fullName, style: MonoStyles.value),
            const SizedBox(height: 4),
            Text('NIK: ${widget.profile.employeeId}', style: MonoStyles.small),
            const SizedBox(height: 16),

            _label('SHIFT KERJA'),
            DropdownButtonFormField<String>(
              initialValue: _selectedShift,
              dropdownColor: AppColors.slateDark,
              style: const TextStyle(color: AppColors.textPrimary, fontSize: 13),
              decoration: const InputDecoration(isDense: true),
              items: WorkerProfile.shifts.map((s) => DropdownMenuItem(value: s, child: Text(s, style: const TextStyle(fontSize: 13)))).toList(),
              onChanged: (v) => setState(() => _selectedShift = v!),
            ),
            const SizedBox(height: 16),

            _label('AREA / LINE'),
            DropdownButtonFormField<String>(
              initialValue: _selectedArea,
              dropdownColor: AppColors.slateDark,
              style: const TextStyle(color: AppColors.textPrimary, fontSize: 13),
              decoration: const InputDecoration(isDense: true),
              items: WorkerProfile.workAreas.map((a) => DropdownMenuItem(value: a, child: Text(a, style: const TextStyle(fontSize: 13)))).toList(),
              onChanged: (v) => setState(() => _selectedArea = v!),
            ),
            const SizedBox(height: 20),

            _label('NAMA NODE'),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.slateDark,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppColors.surfaceBorder),
              ),
              child: Text(
                WorkerProfile.generateNodeName(_nameCtrl.text, _selectedArea),
                style: const TextStyle(color: AppColors.industrialAmber, fontFamily: 'monospace', fontSize: 14, fontWeight: FontWeight.w700),
              ),
            ),
            const SizedBox(height: 20),

            _label('MODE PERANGKAT'),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: AppColors.slateDark,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppColors.surfaceBorder),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: _modeTile(
                          icon: Icons.storage_rounded,
                          label: 'Full Node',
                          subtitle: 'Simpan semua SOP + model lokal',
                          selected: _isFullNode,
                          onTap: () => setState(() => _isFullNode = true),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: _modeTile(
                          icon: Icons.light_mode_rounded,
                          label: 'Light Node',
                          subtitle: 'Cache SOP terdekat saja',
                          selected: !_isFullNode,
                          onTap: () => setState(() => _isFullNode = false),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Text(
                    _isFullNode
                        ? 'Full Node: Menyimpan semua dokumen SOP & model GGUF. Membutuhkan storage lebih.'
                        : 'Light Node: Hanya cache SOP dari rekan 1 hop jauhnya. Hemat storage.',
                    style: const TextStyle(color: AppColors.textMuted, fontSize: 11),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),

            _label('CACHE MODEL GGUF'),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: AppColors.slateDark,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppColors.surfaceBorder),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const PulseDot(color: AppColors.success),
                      const SizedBox(width: 8),
                      const Expanded(child: Text('Qwen 3.5-0.8B Q4_K_M', style: MonoStyles.value)),
                      Text('620 MB', style: MonoStyles.small),
                    ],
                  ),
                  const SizedBox(height: 8),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: const LinearProgressIndicator(
                      value: 0.37,
                      minHeight: 6,
                      backgroundColor: AppColors.slateMuted,
                      valueColor: AlwaysStoppedAnimation(AppColors.cyanAccent),
                    ),
                  ),
                  const SizedBox(height: 4),
                  const Text('620 / 1280 MB digunakan', style: TextStyle(color: AppColors.textMuted, fontSize: 10)),
                ],
              ),
            ),
            const SizedBox(height: 24),

            FilledButton.icon(
              onPressed: _save,
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.industrialAmber,
                foregroundColor: AppColors.slateDark,
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
              icon: const Icon(Icons.save_rounded),
              label: const Text('Simpan Perubahan', style: TextStyle(fontWeight: FontWeight.w700)),
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  Widget _label(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(
          text,
          style: const TextStyle(color: AppColors.textMuted, fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 0.8),
        ),
      );

  Widget _modeTile({
    required IconData icon,
    required String label,
    required String subtitle,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: selected ? AppColors.industrialAmber.withValues(alpha: 0.12) : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected ? AppColors.industrialAmber : AppColors.surfaceBorder,
            width: selected ? 2 : 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: selected ? AppColors.industrialAmber : AppColors.textMuted, size: 20),
            const SizedBox(height: 6),
            Text(label, style: TextStyle(color: selected ? AppColors.textPrimary : AppColors.textSecondary, fontSize: 12, fontWeight: FontWeight.w700)),
            const SizedBox(height: 2),
            Text(subtitle, style: const TextStyle(color: AppColors.textMuted, fontSize: 9)),
          ],
        ),
      ),
    );
  }
}
