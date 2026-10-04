import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/models/mesh_node.dart';
import '../../core/theme/app_colors.dart';
import '../../core/widgets/responsive_shell.dart';
import 'cubit/mesh_cubit.dart';
import 'widgets/desktop_mesh_view.dart';
import 'widgets/mobile_mesh_view.dart';
import 'widgets/node_action_sheet.dart';
import 'widgets/peers_cache_panel.dart';
import 'widgets/qr_pair_sheet.dart';
import 'widgets/sync_status_panel.dart';

/// P2P Mesh Dashboard & Local Daemon Node Control.
/// Entry point responsif: pilih [DesktopMeshView] / [MobileMeshView]
/// dan menampung state bersama + FAB QR pairing yang dapat digeser.
class MeshScreen extends StatefulWidget {
  const MeshScreen({super.key});

  @override
  State<MeshScreen> createState() => _MeshScreenState();
}

class _MeshScreenState extends State<MeshScreen> {
  final Map<String, bool> _sharedCaches = {};

  Timer? _timer;
  double _upRate = 1.4;
  double _downRate = 0.9;

  /// Posisi FAB QR dalam koordinat RELATIF (fraksi 0..1 terhadap ukuran
  /// layar). Disimpan relatif supaya window di-resize / tablet rotate FAB
  /// tetap "menempel" proporsional di tempatnya — bukan nyangkut di koordinat
  /// absolut yang bisa jatuh keluar layar atau melompat.
  Offset? _fabFraction;

  late List<MeshTransfer> _transfers = const [];

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 2), (_) => _tick());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _tick() {
    // Tidak ada simulasi trafik fake: progress aktif hanya dari mesh real.
    if (!mounted) return;
    setState(() {
      _upRate = 0;
      _downRate = 0;
      _transfers = const [];
    });
  }

  bool _isModelFile(String name) {
    final n = name.toLowerCase();
    return (n.contains('lfm') || n.contains('qwen')) && n.endsWith('.gguf');
  }

  /// Daftar transfer yang boleh ditampilkan. Node MUTI WAJIB hanya
  /// menampilkan status seed model bila benar-benar memegang file GGUF
  /// lokal yang valid ([MeshMonitorState.modelHosted]). Bila tidak, baris
  /// model ditampilkan sebagai **unhosted** (0%, tidak ada klaim seed) —
  /// supaya tidak ada false positive hosting.
  List<MeshTransfer> _displayTransfers(MeshMonitorState state) {
    return [
      for (final t in _transfers)
        if (_isModelFile(t.name) && !state.modelHosted)
          MeshTransfer(
            name: t.name,
            detail: 'unhosted · model lokal belum ada',
            progress: 0,
          )
        else
          t,
    ];
  }

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<MeshMonitorCubit, MeshMonitorState>(
      builder: (context, state) {
        return LayoutBuilder(
          builder: (context, constraints) {
            final isDesktop = constraints.maxWidth >= kDesktopBreakpoint;
            // Ukuran CONTENT AREA (dari LayoutBuilder), bukan layar penuh:
            // di dalam ResponsiveShell area konten lebih sempit dari layar
            // (ada nav/sidebar) — memakai MediaQuery membuat FAB duduk di
            // koordinat layar yang melebihi batas Stack sehingga overflow
            // ke kanan. Ukuran content dijadikan basis semua perhitungan FAB.
            final media = MediaQuery.of(context).size;
            final contentSize = Size(
              constraints.maxWidth.isFinite ? constraints.maxWidth : media.width,
              constraints.maxHeight.isFinite
                  ? constraints.maxHeight
                  : media.height,
            );
            // Posisi default FAB memakai anchor tegas (right: 16, bottom: 16)
            // via _fabFraction == null — aman dari ukuran transien/degenerate
            // yang bisa bikin fraksi NaN lalu menempel di pojok kiri-atas.
            // _fabFraction hanya diisi setelah user menggeser FAB pertama kali.
            if (_fabFraction != null &&
                (!_fabFraction!.dx.isFinite || !_fabFraction!.dy.isFinite)) {
              _fabFraction = null;
            }

            return Stack(
              children: [
                isDesktop
                    ? _buildDesktop(context, state)
                    : _buildMobile(context, state),
                _buildDraggableFab(context, state, contentSize),
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildDesktop(BuildContext context, MeshMonitorState state) {
    return DesktopMeshView(
      state: state,
      sharedCaches: _sharedCaches,
      onCacheToggle: (name) => _toggleCache(name, state),
      upRate: _upRate,
      downRate: _downRate,
      transfers: _displayTransfers(state),
      onOpenQrPair: () => _openQrPair(context, state),
      onPeerTap: (node) => _onNodeTap(context, node),
    );
  }

  Widget _buildMobile(BuildContext context, MeshMonitorState state) {
    return MobileMeshView(
      state: state,
      sharedCaches: _sharedCaches,
      onCacheToggle: (name) => _toggleCache(name, state),
      upRate: _upRate,
      downRate: _downRate,
      transfers: _displayTransfers(state),
      onOpenQrPair: () => _openQrPair(context, state),
      onPeerTap: (node) => _onNodeTap(context, node),
    );
  }

  /// Toggle pembagian cache. File model yang tidak dimiliki node
  /// ([MeshMonitorState.modelHosted] false) TIDAK bisa di-toggle — switch
  /// sudah dikunci-off di UI, ini jaring pengaman tambahan.
  void _toggleCache(String name, MeshMonitorState state) {
    final candidates = buildCacheItems(state).where((c) => c.name == name).toList();
    if (candidates.isNotEmpty &&
        candidates.first.requiresLocalFile &&
        !state.modelHosted) {
      return;
    }
    final previous = _sharedCaches[name] ??
        (candidates.isNotEmpty && candidates.first.requiresLocalFile ? false : true);
    setState(() => _sharedCaches[name] = !previous);
  }

  Widget _buildDraggableFab(BuildContext context, MeshMonitorState state, Size size) {
    // FAB material default = 56px. Batas kiri/top dihitung dari ukuran
    // CONTENT AREA (bukan layar) supaya FAB selalu utuh di dalam Stack:
    //   - left maks = width - 56 - 16 → tepi kanan FAB minimal 16px dari
    //     tepi kanan area, tidak pernah overflow.
    //   - FAB juga dinaikkan bila area menyempit (Math.max) agar clamp tidak
    //     terbalik (min > max).
    const fab = 56.0;
    final rightMargin = 16.0;
    final leftBound = math.max(12.0, size.width - fab - rightMargin);
    final topBound = math.max(56.0, size.height - fab - 16.0);
    // Posisi piksel FAB saat ini: default (belum pernah digeser) → patok ke
    // pojok kanan-bawah; kalau sudah digeser → fraksi × ukuran dengan clamp.
    final currentLeft = _fabFraction == null
        ? leftBound
        : (_fabFraction!.dx * size.width).clamp(12.0, leftBound);
    final currentTop = _fabFraction == null
        ? topBound
        : (_fabFraction!.dy * size.height).clamp(56.0, topBound);

    final fabChild = GestureDetector(
      onPanUpdate: (details) {
        setState(() {
          final next = Offset(
            ((currentLeft + details.delta.dx) / size.width)
                .clamp(12.0 / size.width, leftBound / size.width),
            ((currentTop + details.delta.dy) / size.height)
                .clamp(56.0 / size.height, topBound / size.height),
          );
          _fabFraction = (next.dx.isFinite && next.dy.isFinite) ? next : null;
        });
      },
      child: FloatingActionButton(
        onPressed: () => _openQrPair(context, state),
        backgroundColor: AppColors.cyanAccent,
        foregroundColor: AppColors.slateDark,
        tooltip: 'QR Instant Pairing (Geser untuk memindahkan)',
        child: const Icon(Icons.qr_code_scanner_rounded),
      ),
    );

    // Default: anchor langsung ke tepi kanan/bawah area konten (right:16,
    // bottom:16) supaya selalu di pojok kanan-bawah di semua platform.
    // Setelah digeser: Positioned absolut hasil fraksi user.
    if (_fabFraction == null) {
      return Positioned(
        right: rightMargin,
        bottom: 16.0,
        child: fabChild,
      );
    }

    return Positioned(
      left: currentLeft,
      top: currentTop,
      child: fabChild,
    );
  }

  void _openQrPair(BuildContext context, MeshMonitorState state) {
    final nodeName = state.profile?.nodeName ?? state.localDeviceId;
    final payload = 'TPAIR://${state.localDeviceId}|${state.profile?.workArea ?? 'UNKNOWN'}';
    QrPairSheet.show(context, nodeName: nodeName, qrPayload: payload);
  }

  void _onNodeTap(BuildContext context, MeshNode node) {
    NodeActionSheet.show(context, node);
  }
}