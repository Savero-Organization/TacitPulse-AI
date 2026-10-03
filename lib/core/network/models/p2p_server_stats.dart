// p2p_server_stats.dart — metrik realtime server P2P.

/// Statistik transfer realtime yang dikirim dari isolate server.
class P2pServerStats {
  const P2pServerStats({
    required this.activeConnections,
    required this.currentSpeedBytesPerSec,
    required this.totalBytesServed,
    required this.isRunning,
  });

  final int activeConnections;
  final double currentSpeedBytesPerSec;
  final int totalBytesServed;
  final bool isRunning;

  P2pServerStats copyWith({
    int? activeConnections,
    double? currentSpeedBytesPerSec,
    int? totalBytesServed,
    bool? isRunning,
  }) {
    return P2pServerStats(
      activeConnections: activeConnections ?? this.activeConnections,
      currentSpeedBytesPerSec:
          currentSpeedBytesPerSec ?? this.currentSpeedBytesPerSec,
      totalBytesServed: totalBytesServed ?? this.totalBytesServed,
      isRunning: isRunning ?? this.isRunning,
    );
  }

  Map<String, dynamic> toMap() => {
        'activeConnections': activeConnections,
        'currentSpeedBytesPerSec': currentSpeedBytesPerSec,
        'totalBytesServed': totalBytesServed,
        'isRunning': isRunning,
      };

  factory P2pServerStats.fromMap(Map<String, dynamic> map) {
    return P2pServerStats(
      activeConnections: map['activeConnections'] as int,
      currentSpeedBytesPerSec:
          (map['currentSpeedBytesPerSec'] as num).toDouble(),
      totalBytesServed: map['totalBytesServed'] as int,
      isRunning: map['isRunning'] as bool,
    );
  }

  static const empty = P2pServerStats(
    activeConnections: 0,
    currentSpeedBytesPerSec: 0,
    totalBytesServed: 0,
    isRunning: false,
  );
}
