import 'dart:async';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/models/mesh_node.dart';
import '../../../core/models/worker_profile.dart';
import '../../../core/utils/model_loader.dart';
class MeshMonitorState {
  const MeshMonitorState({
    required this.nodes,
    required this.storage,
    required this.meshStats,
    this.profile,
    this.isLocalFullNode = true,
    this.uptimeTicks = 0,
    this.localDeviceId = 'TEK-LOKAL-01',
    this.modelHosted = false,
    this.activeModelFileName,
  });

  final List<MeshNode> nodes;
  final LocalStorageStatus storage;
  final MeshMeshStats meshStats;
  final WorkerProfile? profile;
  final bool isLocalFullNode;
  final int uptimeTicks;
  final String localDeviceId;

  /// Seeding-sifat: nama file model chat yang sedang di-resolve. Dipakai
  /// untuk menampilkan item model di Knowledge Caches (default OFF).
  final String? activeModelFileName;

  /// Benar bila node lokal memegang file model GGUF target yang tervalidasi
  /// (hasil [ModelManager.resolveModelPath] != null). Hanya saat bernilai
  /// `true` node berhak menampilkan/menyiarkan status seed model via P2P
  /// BitSwap. `false` → model dilaporkan unhosted / 0% / tidak aktif.
  final bool modelHosted;

  MeshMonitorState copyWith({
    List<MeshNode>? nodes,
    LocalStorageStatus? storage,
    MeshMeshStats? meshStats,
    WorkerProfile? profile,
    int? uptimeTicks,
    bool? modelHosted,
    String? activeModelFileName,
  }) {
    return MeshMonitorState(
      nodes: nodes ?? this.nodes,
      storage: storage ?? this.storage,
      meshStats: meshStats ?? this.meshStats,
      profile: profile ?? this.profile,
      isLocalFullNode: profile?.isFullNode ?? isLocalFullNode,
      uptimeTicks: uptimeTicks ?? this.uptimeTicks,
      localDeviceId: profile?.nodeName ?? localDeviceId,
      modelHosted: modelHosted ?? this.modelHosted,
      activeModelFileName: activeModelFileName ?? this.activeModelFileName,
    );
  }
}

class MeshMonitorCubit extends Cubit<MeshMonitorState> {
  MeshMonitorCubit()
      : super(MeshMonitorState(
          nodes: const [],
          storage: _placeholderStorage,
          meshStats: const MeshMeshStats(
            connectedNodes: 0,
            kbucketsActive: 0,
            syncedBytesMb: 0,
          ),
        )) {
    _loadProfile();
    refreshModelStatus();
  }

  static const LocalStorageStatus _placeholderStorage = LocalStorageStatus(
    totalGb: 0,
    usedGb: 0,
    modelCacheGb: 0,
    documents: 0,
    voiceNotes: 0,
    modelName: '-',
    modelSizeMb: 0,
  );

  Timer? _ticker;

  Future<void> _loadProfile() async {
    final prefs = await SharedPreferences.getInstance();
    final json = prefs.getString('worker_profile');
    if (json == null || isClosed) return;
    final profile = WorkerProfile.fromJson(json);
    emit(state.copyWith(profile: profile, nodes: const []));
  }

  /// Cek lokal: apakah node benar-benar memegang model GGUF yang valid
  /// untuk di-host? Memakai [ModelManager.resolveModelPath] sehingga hasil
  /// mencerminkan storage / custom path / mesh-cache asli — bukan asumsi.
  ///
  /// Tidak pernah melempar; apapun kegagalan (mis. platform channel tidak
  /// tersedia saat test) → [MeshMonitorState.modelHosted] menjadi `false`.
  Future<void> refreshModelStatus() async {
    var hosted = false;
    String? name;
    try {
      final path = await ModelManager.resolveModelPath();
      hosted = path != null;
      name = path == null ? '' : path.split('/').last;
    } catch (_) {
      hosted = false;
      name = '';
    }
    if (isClosed) return;
    if (hosted == state.modelHosted && name == state.activeModelFileName) return;
    emit(state.copyWith(modelHosted: hosted, activeModelFileName: name));
  }

  void start() {
    _ticker ??= Timer.periodic(const Duration(seconds: 3), (_) => _tick());
  }

  void _tick() {
    if (isClosed) return;
    final connected =
        state.nodes.where((n) => n.status != NodeStatus.offline).length;
    emit(state.copyWith(
      meshStats: MeshMeshStats(
        connectedNodes: connected,
        kbucketsActive: state.meshStats.kbucketsActive,
        syncedBytesMb: state.meshStats.syncedBytesMb,
      ),
      uptimeTicks: state.uptimeTicks + 1,
    ));
  }

  void reloadProfile() {
    _loadProfile();
    refreshModelStatus();
  }

  void setNodeRole({required bool isFullNode}) {
    if (isClosed) return;
    emit(MeshMonitorState(
      nodes: state.nodes,
      storage: state.storage,
      meshStats: state.meshStats,
      profile: state.profile,
      isLocalFullNode: isFullNode,
      uptimeTicks: state.uptimeTicks,
      localDeviceId: state.localDeviceId,
      modelHosted: state.modelHosted,
      activeModelFileName: state.activeModelFileName,
    ));
  }

  @override
  Future<void> close() {
    _ticker?.cancel();
    _ticker = null;
    return super.close();
  }
}