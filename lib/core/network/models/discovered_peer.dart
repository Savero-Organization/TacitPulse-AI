// discovered_peer.dart — model immutable satu peer Tacit Pulse di LAN.

import 'dart:convert';

/// Satu instance Tacit Pulse AI yang ditemukan via mDNS.
class DiscoveredPeer {
  const DiscoveredPeer({
    required this.id,
    required this.name,
    required this.host,
    required this.addresses,
    required this.port,
    this.txtRecords = const {},
    required this.lastSeen,
  });

  final String id;
  final String name;
  final String host;
  final List<String> addresses;
  final int port;
  final Map<String, String> txtRecords;
  final DateTime lastSeen;

  String get primaryAddress => addresses.isNotEmpty ? addresses.first : host;

  DiscoveredPeer copyWith({
    String? id,
    String? name,
    String? host,
    List<String>? addresses,
    int? port,
    Map<String, String>? txtRecords,
    DateTime? lastSeen,
  }) {
    return DiscoveredPeer(
      id: id ?? this.id,
      name: name ?? this.name,
      host: host ?? this.host,
      addresses: addresses ?? this.addresses,
      port: port ?? this.port,
      txtRecords: txtRecords ?? this.txtRecords,
      lastSeen: lastSeen ?? this.lastSeen,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'host': host,
        'addresses': addresses,
        'port': port,
        'txtRecords': txtRecords,
        'lastSeen': lastSeen.toIso8601String(),
      };

  factory DiscoveredPeer.fromJson(Map<String, dynamic> json) {
    return DiscoveredPeer(
      id: json['id'] as String,
      name: json['name'] as String,
      host: json['host'] as String? ?? '',
      addresses: (json['addresses'] as List?)?.cast<String>() ?? const [],
      port: json['port'] as int,
      txtRecords: (json['txtRecords'] as Map?)?.cast<String, String>() ??
          const {},
      lastSeen: DateTime.parse(json['lastSeen'] as String),
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DiscoveredPeer &&
          other.id == id &&
          other.name == name &&
          other.host == host &&
          _listEquals(other.addresses, addresses) &&
          other.port == port &&
          _mapEquals(other.txtRecords, txtRecords);

  @override
  int get hashCode => Object.hash(id, name, host, Object.hashAll(addresses),
      port, Object.hashAll(txtRecords.entries.map((e) => e.key + e.value)));

  @override
  String toString() =>
      'DiscoveredPeer(id: $id, name: $name, host: $host, '
      'addresses: $addresses, port: $port, txtRecords: $txtRecords, '
      'lastSeen: $lastSeen)';

  static bool _listEquals(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static bool _mapEquals(Map<String, String> a, Map<String, String> b) {
    if (a.length != b.length) return false;
    for (final key in a.keys) {
      if (a[key] != b[key]) return false;
    }
    return true;
  }

  /// Decode TXT record NSD (`Map<String, Uint8List?>`) menjadi
  /// `Map<String, String>` UTF-8; entri tak ter-decode dibuang.
  static Map<String, String> decodeTxt(Map<String, dynamic>? txt) {
    if (txt == null) return const {};
    final out = <String, String>{};
    for (final entry in txt.entries) {
      final value = entry.value;
      if (value == null) {
        out[entry.key] = '';
      } else if (value is String) {
        out[entry.key] = value;
      } else {
        try {
          out[entry.key] = utf8.decode(value as List<int>);
        } catch (_) {
          // abaikan entri tidak ter-decode
        }
      }
    }
    return out;
  }
}
