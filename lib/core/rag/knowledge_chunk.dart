import 'dart:ui';

import '../models/citation.dart';

/// Satu dokumen/sumber yang bisa di-retrieve oleh [IntentRouter].
///
/// Ini adalah representasi lokal dari "vector index" yang masih mock di UI
/// mesh: chunk knowledge ditambatkan ke terminologi operasional (keyword)
/// dan diskor dengan cosine similarity ringan di atas vocabulary query.
/// Bila supabase/vector DB nyata sudah dipasang, cukup ganti bagian scoring
/// di IntentRouter — kontrak [KnowledgeChunk] tetap.
class KnowledgeChunk {
  const KnowledgeChunk({
    required this.id,
    required this.title,
    required this.type,
    required this.page,
    required this.snippet,
    required this.keywords,
    this.boundingBox = const Rect.fromLTWH(0.08, 0.32, 0.6, 0.2),
  });

  final String id;
  final String title;
  final CitationType type;
  final int page;

  /// Potongan teks yang diinjeksikan ke prompt sistem sebagai referensi.
  final String snippet;

  /// Terma operasional (lowercase) yang menjadi vocabulary scoring.
  final List<String> keywords;

  /// Bounding box relatif (0..1) pada halaman PDF/SOP.
  final Rect boundingBox;

  /// Menghasilkan [SourceCitation] untuk UI chat (tab sumber).
  SourceCitation toCitation(double score) {
    return SourceCitation(
      id: 'chunk-${id.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '-')}',
      title: title,
      type: type,
      page: page,
      snippet: snippet,
      score: score.clamp(0.0, 1.0),
      boundingBox: boundingBox,
    );
  }
}

/// Korpus knowledge lokal (stand-in sementara untuk vector DB/embedding).
///
/// Topik menyesuaikan domain demo: maintenance pabrik, kompresor screw,
/// alarm pressure switch, CIP, boiler, dan kalibrasi timbangan. Keyword
/// dipilih agar pembobotan cosine punya pembeda yang masuk akal untuk
/// pertanyaan-pertanyaan khas teknisi.
const List<KnowledgeChunk> kKnowledgeCorpus = [
  KnowledgeChunk(
    id: 'kom-014',
    title: 'SOP PM-KOM-014: Cold Start Kompresor Screw',
    type: CitationType.sop,
    page: 3,
    snippet:
        'Cold start: buka oil valve, pastikan tekanan oli stabil 3,5 bar '
        'dalam 5 detik sebelum beban dibuka; suhu oli minimal 25\u00b0C. '
        'Bila tekanan di bawah 3,0 bar, lakukan purging sirkuit oli.',
    keywords: [
      'tekanan',
      'oli',
      'cold',
      'start',
      'kompresor',
      'screw',
      '3,5',
      '3.5',
      'bar',
    ],
  ),
  KnowledgeChunk(
    id: 'ga75-oil',
    title: 'Manual Atlas Copco GA75 - Bab Tekanan Oli',
    type: CitationType.pdf,
    page: 14,
    snippet:
        'Pressure (oil) yang direkomendasikan: 3.0 - 4.0 bar pada kondisi hangat.',
    keywords: [
      'tekanan',
      'oli',
      'atlas',
      'copco',
      'ga75',
      'hangat',
      'bar',
      'pressure',
    ],
  ),
  KnowledgeChunk(
    id: 'kom-014-alarm',
    title: 'SOP PM-KOM-014: Alarm AA-221 Pressure Switch',
    type: CitationType.sop,
    page: 4,
    snippet:
        'AA-221 = pressure switch tidak terbaca (sensor/relay K2). '
        'Tindakan aman pertama: kunci panel (LOTO), cek kabel sensor di '
        'relay K2, catat foto sebelum mengganti komponen.',
    keywords: [
      'alarm',
      'aa-221',
      'aa221',
      'pressure',
      'switch',
      'loto',
      'panel',
      'k2',
      'aman',
      'tindakan',
      'error',
    ],
  ),
  KnowledgeChunk(
    id: 'anomali-line2',
    title: 'Log Anomali Mesin - Line 2',
    type: CitationType.worklog,
    page: 1,
    snippet:
        'Anomali AA-221 kompresor Line 2 tercatat 3x minggu ini; '
        'semua diawali sensor pressure switch di relay K2.',
    keywords: ['anomali', 'aa-221', 'aa221', 'line', '2', 'pressure'],
  ),
  KnowledgeChunk(
    id: 'fil-008',
    title: 'SOP PM-FIL-008: CIP Line Filling',
    type: CitationType.sop,
    page: 2,
    snippet:
        'CIP line: urutkan flushing air, detergent cycle, rinse acids, '
        'lalu bilas dengan air demineral sampai pH netral.',
    keywords: ['cip', 'line', 'filling', 'flush', 'detergent', 'rinse', 'ph'],
  ),
  KnowledgeChunk(
    id: 'boil-003',
    title: 'SOP PM-BOIL-003: Cold Start Boiler',
    type: CitationType.sop,
    page: 5,
    snippet:
        'Cold start boiler: buka vent atas, nyalakan pilot, naikkan tekanan '
        'uap bertahap 0,5 bar/10 menit sampai tekanan kerja.',
    keywords: ['boiler', 'uap', 'pilot', 'vent', 'steam', 'cold start'],
  ),
  KnowledgeChunk(
    id: 'mix-015',
    title: 'SOP PM-MIX-015: Kalibrasi Timbangan',
    type: CitationType.sop,
    page: 7,
    snippet:
        'Kalibrasi timbangan: gunakan anak timbangan standar, toleransi '
        '\u00b10,2 kg, catat deviasi di log harian.',
    keywords: ['kalibrasi', 'timbangan', 'anak', 'timbangan', 'deviasi', 'log'],
  ),
];