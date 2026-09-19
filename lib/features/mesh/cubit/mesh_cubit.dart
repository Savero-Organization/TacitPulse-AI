import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/models/mesh_node.dart';
import '../../../core/models/worker_profile.dart';
import '../../mock_data.dart';

class MeshMonitorState {
  const MeshMonitorState({
    required this.nodes,
    required this.storage,
    required this.meshStats,
    this.profile,
    this.isLocalFullNode = true,
    this.uptimeTicks = 0,
    this.localDeviceId = 'TEK-LOKAL-01',
  });

  final List<MeshNode> nodes;
  final LocalStorageStatus storage;
  final MeshMeshStats meshStats;
  final WorkerProfile? profile;
  final bool isLocalFullNode;
  final int uptimeTicks;
  final String localDeviceId;

  MeshMonitorState copyWith({
    List<MeshNode>? nodes,
    LocalStorageStatus? storage,
    MeshMeshStats? meshStats,
    WorkerProfile? profile,
    int? uptimeTicks,
  }) {
    return MeshMonitorState(
      nodes: nodes ?? this.nodes,
      storage: storage ?? this.storage,
      meshStats: meshStats ?? this.meshStats,
      profile: profile ?? this.profile,
      isLocalFullNode: profile?.isFullNode ?? isLocalFullNode,
      uptimeTicks: uptimeTicks ?? this.uptimeTicks,
      localDeviceId: profile?.nodeName ?? localDeviceId,
    );
  }
}

class MeshMonitorCubit extends Cubit<MeshMonitorState> {
  MeshMonitorCubit()
      : super(MeshMonitorState(
          nodes: MockData.buildNodes(),
          storage: MockData.buildStorage(),
          meshStats: MockData.buildMeshStats,
        )) {
    _loadProfile();
  }

  final math.Random _rnd = math.Random(7);
  Timer? _ticker;

  Future<void> _loadProfile() async {
    final prefs = await SharedPreferences.getInstance();
    final json = prefs.getString('worker_profile');
    if (json == null || isClosed) return;
    final profile = WorkerProfile.fromJson(json);
    emit(state.copyWith(profile: profile, nodes: MockData.buildNearbyTechs(profile.nodeName)));
  }

  void start() {
    _ticker ??= Timer.periodic(const Duration(seconds: 3), (_) => _tick());
  }

  void _tick() {
    if (isClosed) return;
    final now = state;
    var i = 0;
    final nodes = now.nodes.map((n) {
      if (n.status == NodeStatus.offline) return n.copyWith(status: NodeStatus.offline);
      i++;
      final status = i % 11 == 0 ? NodeStatus.syncing : NodeStatus.online;
      return n.copyWith(
        status: status,
        peers: math.max(1, n.peers + _rnd.nextInt(3) - 1),
        cpuLoad: (0.05 + _rnd.nextDouble() * 0.7).clamp(0, 1),
        battery: (n.battery + _rnd.nextInt(3) - 1).clamp(5, 100),
        signal: (n.signal + _rnd.nextInt(5) - 2).clamp(1, 4),
      );
    }).toList();

    final connected = nodes.where((n) => n.status != NodeStatus.offline).length;
    emit(now.copyWith(
      nodes: nodes,
      meshStats: MeshMeshStats(
        connectedNodes: connected,
        kbucketsActive: now.meshStats.kbucketsActive + (_rnd.nextBool() ? 1 : 0),
        syncedBytesMb: now.meshStats.syncedBytesMb + _rnd.nextInt(3),
      ),
      uptimeTicks: now.uptimeTicks + 1,
    ));
  }

  void reloadProfile() {
    _loadProfile();
  }

  @override
  Future<void> close() {
    _ticker?.cancel();
    _ticker = null;
    return super.close();
  }
}