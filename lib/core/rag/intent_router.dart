import 'dart:math' as math;

import '../models/citation.dart';
import 'knowledge_chunk.dart';

/// Jenis intent hasil [IntentRouter] sebelum prompt dikondisikan.
enum IntentKind {
  /// Salam / sapaan pendek — fast path, tanpa RAG.
  greeting,

  /// Aritmetika sederhana — fast path, tanpa RAG.
  math,

  /// Frasa sangat pendek / pertanyaan ringan — fast path, tanpa RAG.
  generalShortcut,

  /// Pertanyaan operasional yang harus melewati similarity ke korpus.
  question,
}

/// Ambang skor kemiripan (0..1) untuk menginjeksikan chunk referensi.
/// < 0.35: context dikosongkan dan model memakai prompt umum.
/// >= 0.35: chunk top-N dimasukkan ke prompt sistem + operational prompt.
const double kRagScoreThreshold = 0.35;

/// Prompt sistem "ringan" untuk jalur cepat (greeting/math/frasa pendek)
/// maupun pertanyaan yang tidak punya kecocokan korpus — tanpa dorongan
/// menjawab dari sumber.
const String kGeneralSystemPrompt =
    'Kamu adalah asisten teknisi maintenance pabrik. Jawab singkat, padat, '
    'dan ramah. Bila perlu perhitungan sederhana, hitung dengan benar. '
    'Jangan mengarang detail prosedural yang tidak kamu tahu.';

/// Prompt sistem "operasional" untuk pertanyaan yang melewati ambang RAG:
/// model diarahkan menjawab HANYA dari referensi yang diinjeksikan.
const String kOperationalSystemPrompt =
    'Kamu adalah asisten teknisi maintenance pabrik. Jawab singkat, padat, '
    'dan langsung praktis. Gunakan referensi dokumen yang diberikan di '
    'bawah; jawab HANYA dari sumber itu. Sebutkan kode SOP/PDF sebagai '
    'rujukan. Jangan menebak fakta yang tidak ada di referensi.';

/// Ambang ukuran maksimal fraksi "frasa pendek" yang dianggap fast path.
const int kFastPathMaxWords = 2;
const int kFastPathMaxChars = 12;

/// Chunk yang lolos ambang bersama skornya.
class ScoredChunk {
  const ScoredChunk({required this.chunk, required this.score});

  final KnowledgeChunk chunk;
  final double score;
}

/// Hasil keputusan routing untuk satu pertanyaan user.
class RoutingDecision {
  const RoutingDecision({
    required this.kind,
    required this.topScore,
    required this.matches,
  });

  final IntentKind kind;

  /// Skor tertinggi dari semua chunk (0..1); 0 bila tidak ada chunk.
  final double topScore;

  /// Chunk yang lolos ambang [kRagScoreThreshold], diurutkan skor turun.
  final List<ScoredChunk> matches;

  List<KnowledgeChunk> get contextChunks => [for (final m in matches) m.chunk];

  bool get usesRag => matches.isNotEmpty;

  String get systemPrompt =>
      usesRag ? kOperationalSystemPrompt : kGeneralSystemPrompt;

  /// Blok referensi yang diinjeksikan ke prompt sistem (kosong tanpa RAG).
  String get contextDocs {
    if (matches.isEmpty) return '';
    final buf = StringBuffer();
    for (var i = 0; i < matches.length; i++) {
      final c = matches[i].chunk;
      buf.write('[${i + 1}] ${c.title} (hlm. ${c.page}): ${c.snippet}\n');
    }
    return buf.toString().trim();
  }

  /// Citation untuk UI chat; kosong bila jalur tanpa RAG.
  List<SourceCitation> get citations => [
    for (final m in matches) m.chunk.toCitation(m.score),
  ];
}

/// Router intent shallow → prompt conditioning.
///
/// Alur:
///   1. Fast path regex (salam / matematika / frasa pendek) → tanpa RAG,
///      memakai prompt umum + contextDocs kosong.
///   2. Selain itu lakukan similarity ringan ke [kKnowledgeCorpus]:
///      sparse cosine di atas vocabulary query vs keyword chunk.
///   3. topScore < [kRagScoreThreshold] → context dibuang (prompt umum);
///      >= ambang → chunk top-N diinjeksi + prompt operasional.
class IntentRouter {
  IntentRouter({List<KnowledgeChunk>? corpus})
    : _corpus = corpus ?? kKnowledgeCorpus;

  static final IntentRouter instance = IntentRouter();

  final List<KnowledgeChunk> _corpus;

  static final RegExp _greetingRegExp = RegExp(
    r'^(halo|hai|hallo|hello|hi|hey|hei|pagi|siang|sore|malam|'
    r'assalamualaikum|selamat\s+(pagi|siang|sore|malam)|'
    r'terima\s+kasih|terimakasih|makasih|thanks|thank\s+you)\b',
    caseSensitive: false,
  );

  static final RegExp _mathRegExp = RegExp(r'\d[\d.,]*\s*[+\-*/%^]\s*\d[\d.,]*');

  static const Set<String> _stopWords = {
    'apa',
    'berapa',
    'yang',
    'di',
    'ke',
    'dengan',
    'untuk',
    'pada',
    'dari',
    'agar',
    'supaya',
    'saat',
    'ini',
    'itu',
    'the',
    'a',
    'an',
    'of',
    'to',
    'for',
    'is',
    'are',
  };

  /// Merutekan satu pertanyaan ke keputusan prompt conditioning.
  RoutingDecision route(String question) {
    final q = question.trim();
    if (q.isEmpty) {
      return _fastPath(IntentKind.generalShortcut);
    }
    if (_greetingRegExp.hasMatch(q)) {
      return _fastPath(IntentKind.greeting);
    }
    if (_mathRegExp.hasMatch(q)) {
      return _fastPath(IntentKind.math);
    }
    if (_isShortPhrase(q)) {
      return _fastPath(IntentKind.generalShortcut);
    }

    final queryTokens = _tokenize(q);
    final scored = <ScoredChunk>[
      for (final chunk in _corpus)
        ScoredChunk(chunk: chunk, score: _cosine(queryTokens, chunk)),
    ]..sort((a, b) => b.score.compareTo(a.score));

    final topScore = scored.isEmpty ? 0.0 : scored.first.score;
    final matches = scored
        .where((s) => s.score >= kRagScoreThreshold)
        .toList(growable: false);

    return RoutingDecision(
      kind: IntentKind.question,
      topScore: topScore,
      matches: matches,
    );
  }

  RoutingDecision _fastPath(IntentKind kind) {
    return RoutingDecision(kind: kind, topScore: 0, matches: const []);
  }

  bool _isShortPhrase(String q) {
    final words = q.split(RegExp(r'\s+'));
    return words.length <= kFastPathMaxWords && q.length <= kFastPathMaxChars;
  }

  /// Tokenisasi query: huruf kecil, buang tanda baca & stop word.
  List<String> _tokenize(String q) {
    final lower = q.toLowerCase();
    final words = lower.split(RegExp(r'[^a-z0-9.,+\-*/]+'));
    return [
      for (final w in words) if (w.isNotEmpty && !_stopWords.contains(w)) w,
    ];
  }

  /// Sparse cosine similarity antara token query dan keyword chunk.
  ///
  /// Query dilihat sebagai vektor biner di vocabulary = token query + keyword
  /// chunk; keyword yang cocok mengisi dimensi yang sama, sehingga chunk
  /// relevan mendapat skor tinggi dan chunk tak relevan jatuh di bawah
  /// [kRagScoreThreshold].
  double _cosine(List<String> queryTokens, KnowledgeChunk chunk) {
    if (queryTokens.isEmpty) return 0;

    final normQuery = queryTokens.join(' ');
    final chunkTerms = chunk.keywords.map((k) => k.toLowerCase()).toSet();

    var dot = 0;
    for (final term in chunkTerms) {
      if (_termMatches(term, queryTokens, normQuery)) dot += 1;
    }
    if (dot == 0) return 0;

    final qMag = math.sqrt(queryTokens.length.toDouble());
    final cMag = math.sqrt(chunkTerms.length.toDouble());
    if (qMag == 0 || cMag == 0) return 0;
    return dot / (qMag * cMag);
  }

  bool _termMatches(String term, List<String> tokens, String normQuery) {
    if (tokens.contains(term)) return true;
    // Terma bertanda baca (mis. "3,5" vs "3.5") atau multi-kata (mis.
    // "cold start") bisa terpotong tokenizer; substring di query
    // ternormalisasi sebagai pendekatan ringan.
    return term.length >= 2 && normQuery.contains(term);
  }
}