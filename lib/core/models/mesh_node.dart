/// Peran node dalam jaringan P2P Mesh TacitPulse.
enum NodeRole {
  full('Full Node'),
  light('Light Node');

  const NodeRole(this.label);
  final String label;
}

enum NodeStatus {
  online,
  syncing,
  offline;

  String get label => switch (this) {
        NodeStatus.online => 'TERHUBUNG',
        NodeStatus.syncing => 'SYNCING',
        NodeStatus.offline => 'LEPAS',
      };
}

class MeshNode {
  const MeshNode({
    required this.id,
    required this.name,
    required this.role,
    required this.status,
    required this.ip,
    required this.lastSeen,
    this.peers = 0,
    this.storeRecords = 0,
    this.cpuLoad = 0,
    this.technicianName = '',
    this.line = '',
    this.battery = 0,
    this.signal = 0,
    this.recentSop = '',
  });

  final String id;
  final String name;
  final NodeRole role;
  final NodeStatus status;
  final String ip;
  final DateTime? lastSeen;
  final int peers;
  final int storeRecords;
  final double cpuLoad;

  final String technicianName;
  final String line;
  final int battery;
  final int signal;
  final String recentSop;

  MeshNode copyWith({
    NodeStatus? status,
    int? peers,
    int? storeRecords,
    double? cpuLoad,
    int? battery,
    int? signal,
  }) {
    return MeshNode(
      id: id,
      name: name,
      role: role,
      status: status ?? this.status,
      ip: ip,
      lastSeen: status == NodeStatus.offline ? lastSeen : DateTime.now(),
      peers: peers ?? this.peers,
      storeRecords: storeRecords ?? this.storeRecords,
      cpuLoad: cpuLoad ?? this.cpuLoad,
      technicianName: technicianName,
      line: line,
      battery: battery ?? this.battery,
      signal: signal ?? this.signal,
      recentSop: recentSop,
    );
  }
}

/// Status penyimpanan lokal perangkat + cache model GGUF.
class LocalStorageStatus {
  const LocalStorageStatus({
    required this.totalGb,
    required this.usedGb,
    required this.modelCacheGb,
    required this.documents,
    required this.voiceNotes,
    required this.modelName,
    required this.modelSizeMb,
    this.modelLoaded = false,
  });

  final double totalGb;
  final double usedGb;
  final double modelCacheGb;
  final int documents;
  final int voiceNotes;
  final String modelName;
  final double modelSizeMb;
  final bool modelLoaded;

  double get freeGb => (totalGb - usedGb).clamp(0, totalGb);
  double get usageFraction => totalGb <= 0 ? 0 : (usedGb / totalGb).clamp(0, 1);
}

class MeshMeshStats {
  const MeshMeshStats({required this.connectedNodes, required this.kbucketsActive, required this.syncedBytesMb});
  final int connectedNodes;
  final int kbucketsActive;
  final int syncedBytesMb;
}