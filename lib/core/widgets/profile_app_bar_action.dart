import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/models/worker_profile.dart';
import '../../core/theme/app_colors.dart';
import '../../features/mesh/cubit/mesh_cubit.dart';
import '../../features/mesh/widgets/profile_sheet.dart';

/// Tombol Profile di AppBar seluruh halaman.
/// Membuka [ProfileSheet] untuk edit Shift / Line & config node.
class ProfileAppBarAction extends StatelessWidget {
  const ProfileAppBarAction({super.key});

  @override
  Widget build(BuildContext context) {
    return IconButton(
      onPressed: () async {
        final prefs = await SharedPreferences.getInstance();
        final json = prefs.getString('worker_profile');
        if (json == null || !context.mounted) return;
        final profile = WorkerProfile.fromJson(json);
        ProfileSheet.show(context, profile, onSaved: () {
          final meshCtx = context.read<MeshMonitorCubit>();
          meshCtx.reloadProfile();
        });
      },
      tooltip: 'Profil & Node Config',
      icon: Stack(
        clipBehavior: Clip.none,
        children: [
          const Icon(Icons.account_circle_rounded, color: AppColors.textSecondary, size: 26),
          Positioned(
            right: -2,
            bottom: -2,
            child: Container(
              width: 10,
              height: 10,
              decoration: const BoxDecoration(
                color: AppColors.industrialAmber,
                shape: BoxShape.circle,
              ),
              child: const Center(
                child: Icon(Icons.bolt, size: 7, color: AppColors.slateDark),
              ),
            ),
          ),
        ],
      ),
    );
  }
}