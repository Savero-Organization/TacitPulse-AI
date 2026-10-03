// p2p_server_config.dart — konfigurasi server P2P lokal.

/// Konfigurasi untuk server HTTP file lokal yang berjalan di isolate.
class P2pServerConfig {
  const P2pServerConfig({
    required this.modelsDirPath,
    required this.port,
    this.maxRateBytesPerSec,
  });

  /// Direktori tempat model file (.gguf) berada.
  final String modelsDirPath;

  /// Port bind server. Port 0 = pilih port bebas (ephemeral).
  final int port;

  /// Batas kecepatan up-load per koneksi pemrosesan (bytes/detik); null = tanpa batas.
  final int? maxRateBytesPerSec;

  Map<String, dynamic> toMap() => {
        'modelsDirPath': modelsDirPath,
        'port': port,
        'maxRateBytesPerSec': maxRateBytesPerSec,
      };

  factory P2pServerConfig.fromMap(Map<String, dynamic> map) {
    return P2pServerConfig(
      modelsDirPath: map['modelsDirPath'] as String,
      port: map['port'] as int,
      maxRateBytesPerSec: map['maxRateBytesPerSec'] as int?,
    );
  }
}
