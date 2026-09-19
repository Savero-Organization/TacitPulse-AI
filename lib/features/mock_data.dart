import 'dart:ui';

import '../core/models/citation.dart';
import '../core/models/chat_message.dart';
import '../core/models/mesh_node.dart';
import '../core/models/tacit_note.dart';

/// Data tiruan (mock) untuk prototipe UI sebelum integrasi
/// native FFI (llama.cpp, whisper.cpp) & P2P Kademlia.
abstract final class MockData {
  static List<MeshNode> buildNodes() => buildNearbyTechs('TEK-LOKAL-01');

  /// Teknisi/stasiun di sekitar dalam radius yang sama (mock P2P discovery).
  static List<MeshNode> buildNearbyTechs(String localDeviceId) => [
        MeshNode(
          id: 'node-00',
          name: localDeviceId,
          role: NodeRole.full,
          status: NodeStatus.online,
          ip: '10.0.3.11',
          lastSeen: null,
          peers: 7,
          storeRecords: 1284,
          cpuLoad: 0.18,
          technicianName: 'Anda',
          line: 'Pribadi',
          battery: 88,
          signal: 4,
          recentSop: '—',
        ),
        const MeshNode(
          id: 'node-01',
          name: 'TEK-LINE2-RINA',
          role: NodeRole.full,
          status: NodeStatus.online,
          ip: '10.0.3.20',
          lastSeen: null,
          peers: 6,
          storeRecords: 980,
          cpuLoad: 0.31,
          technicianName: 'Rina Saraswati',
          line: 'Line 2 - Filling',
          battery: 72,
          signal: 4,
          recentSop: 'SOP PM-FIL-021: Ganti seal transfer',
        ),
        const MeshNode(
          id: 'node-02',
          name: 'TEK-UTIL-BUDI',
          role: NodeRole.full,
          status: NodeStatus.online,
          ip: '10.0.3.21',
          lastSeen: null,
          peers: 5,
          storeRecords: 1132,
          cpuLoad: 0.22,
          technicianName: 'Budi Santoso',
          line: 'Utility & Boiler',
          battery: 95,
          signal: 3,
          recentSop: 'SOP PM-BOIL-003: Cold start boiler',
        ),
        const MeshNode(
          id: 'node-03',
          name: 'TEK-LINE1-DEWI',
          role: NodeRole.light,
          status: NodeStatus.syncing,
          ip: '10.0.3.22',
          lastSeen: null,
          peers: 4,
          storeRecords: 310,
          cpuLoad: 0.48,
          technicianName: 'Dewi Lestari',
          line: 'Line 1 - Packaging',
          battery: 54,
          signal: 2,
          recentSop: 'SOP PM-PKG-007: Setup wrapper',
        ),
        const MeshNode(
          id: 'node-04',
          name: 'TEK-LINE3-ADIT',
          role: NodeRole.light,
          status: NodeStatus.online,
          ip: '10.0.3.23',
          lastSeen: null,
          peers: 3,
          storeRecords: 421,
          cpuLoad: 0.12,
          technicianName: 'Aditya Nugraha',
          line: 'Line 3 - Mixing',
          battery: 61,
          signal: 3,
          recentSop: 'SOP PM-MIX-015: Kalibrasi timbangan',
        ),
        MeshNode(
          id: 'node-05',
          name: 'TEK-LINE2-ANDI',
          role: NodeRole.light,
          status: NodeStatus.offline,
          ip: '10.0.3.24',
          lastSeen: DateTime.now().subtract(const Duration(minutes: 42)),
          peers: 2,
          storeRecords: 205,
          cpuLoad: 0,
          technicianName: 'Andi Kurniawan',
          line: 'Line 2 - Filling',
          battery: 30,
          signal: 1,
          recentSop: 'SOP PM-FIL-008: CIP line',
        ),
      ];

  static LocalStorageStatus buildStorage() => const LocalStorageStatus(
        totalGb: 128,
        usedGb: 47.3,
        modelCacheGb: 0.62,
        documents: 1284,
        voiceNotes: 96,
        modelName: 'Qwen 3.5-0.8B Q4_K_M',
        modelSizeMb: 620,
        modelLoaded: true,
      );

  static const MeshMeshStats buildMeshStats = MeshMeshStats(
    connectedNodes: 5,
    kbucketsActive: 8,
    syncedBytesMb: 142,
  );

  static List<ChatMessage> buildMessages() => [
        ChatMessage(
          id: 'm-0',
          role: ChatRole.user,
          text: 'Berapa tekanan oli yang benar saat cold start kompresor screw?',
          timestamp: DateTime.now().subtract(const Duration(seconds: 90)),
        ),
        ChatMessage(
          id: 'm-1',
          role: ChatRole.assistant,
          text: 'Untuk cold start kompresor screw, tekanan oli harus stabil di 3,5 bar sebelum beban dibuka. '
              'Pastikan suhu oli telah mencapai minimal 25°C. Jika tekanan di bawah 3,0 bar saat 5 detik pertama, '
              'lakukan purging sirkuit oli sesuai SOP PM-KOM-014.',
          timestamp: DateTime.now().subtract(const Duration(seconds: 82)),
          citations: const [
            SourceCitation(
              id: 'c-1',
              title: 'SOP PM-KOM-014: Cold Start Kompresor Screw',
              type: CitationType.sop,
              page: 3,
              snippet:
                  'Cold start: buka oil valve, pastikan tekanan stabil 3,5 bar dalam 5 detik sebelum beban.',
              score: 0.91,
              boundingBox: Rect.fromLTWH(0.06, 0.28, 0.72, 0.16),
            ),
            SourceCitation(
              id: 'c-2',
              title: 'Manual Atlas Copco GA75 - Bab Tekanan Oli',
              type: CitationType.pdf,
              page: 14,
              snippet: 'Pressure (oil) yang direkomendasikan: 3.0 - 4.0 bar pada kondisi hangat.',
              score: 0.82,
              boundingBox: Rect.fromLTWH(0.12, 0.55, 0.5, 0.12),
            ),
          ],
        ),
        ChatMessage(
          id: 'm-2',
          role: ChatRole.user,
          text: 'Kode error "AA-221" muncul di panel, apa tindakan aman pertamanya?',
          timestamp: DateTime.now().subtract(const Duration(seconds: 30)),
        ),
      ];

  static const List<String> _streamWords = [
    'AA-221',
    'menandakan',
    'pressure',
    'switch',
    'tidak',
    'terbaca.',
    'Langkah',
    'aman',
    'pertama:',
    'kunci',
    'panel',
    '(LOTO),',
    'cek',
    'kabel',
    'sensor',
    'di',
    'relay',
    'K2.',
    'Catat',
    'foto',
    'sebelum',
    'mengganti.',
  ];

  static List<String> get streamWords => List.of(_streamWords);

  static List<TacitNote> buildNotes() => [
        TacitNote(
          id: 'n-1',
          title: 'Ganti seal pump transfer yang bocor tanpa bongkar rumah pompa',
          technician: 'Eko Prasetyo',
          line: 'Line 2 - Filling',
          durationSeconds: 54,
          recordedAt: DateTime.now().subtract(const Duration(hours: 2)),
          waveform: buildWaveform(28),
          transcribedText:
              'Kalau seal transfer pump bocor kecil, enggak usah bongkar rumah pompa. '
              'Matikan motor, biarkan pressure release 2 menit. Cukup buka 4 baut coupling guard, '
              'geser selang flexible ke bawah, lalu kunci spindel pakai kunci 17. '
              'Sealnya keluar utuh walau dengan tangan kalau pelumasan oli masih ada.',
          sopSteps: const [
            SopDraftStep(
              order: 1,
              title: 'Persiapan & LOTO',
              detail: 'Matikan motor, kunci main switch, lepaskan pressure dengan buka valve relief 2 menit.',
              confirmed: true,
            ),
            SopDraftStep(
              order: 2,
              title: 'Buka coupling guard',
              detail: 'Lepas 4 baut coupling guard (kunci ring 12). Jangan buka rumah pompa.',
              confirmed: true,
            ),
            SopDraftStep(
              order: 3,
              title: 'Akses seal',
              detail: 'Geser selang flexible ke bawah, kunci spindel dengan kunci 17, tarik seal keluar.',
              confirmed: false,
            ),
          ],
        ),
      ];

  static List<double> buildWaveform(int samples) {
    final rnd = _FakeRandom(42);
    return List<double>.generate(
      samples,
      (i) => 0.3 + 0.55 * ((i * 7).isEven ? 1 : 0.6) * rnd.nextDouble(),
    );
  }
}

/// PRNG sederhana agar data mock stabil antar build (tanpa dep dart:math math.random seed).
class _FakeRandom {
  _FakeRandom(this.seed);
  int seed;

  int _next() {
    seed = (seed * 1664525 + 1013904223) & 0xFFFFFFFF;
    return seed;
  }

  double nextDouble() => _next() / 0xFFFFFFFF;
}