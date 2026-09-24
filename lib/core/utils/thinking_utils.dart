// Utilitas parsing tag berpikir Qwen (` thinking ... response `) dan
// format XML (`<thinking>...</thinking>`), plus sanitizer token kontrol.
//
// Satu sumber kebenaran untuk token pembuka/penutup agar sanitizer context,
// stream-guard di ChatCubit, dan renderer bubble memakai format yang sama.

/// Token pembuka blok berpikir literal Qwen (spasi + "thinking").
const String kThinkingStartToken = ' thinking';

/// Token penutup blok berpikir literal Qwen.
const String kThinkingEndToken = ' response';

/// Tag penutup literal yang diinjeksi guard bila model nyangkut di blok.
const String kThinkingEndTag = ' response\n';

/// Token pembuka blok berpikir style XML (`<thinking>`).
const String kXmlThinkingStartToken = '<thinking>';

/// Token penutup blok berpikir style XML (`</thinking>`).
const String kXmlThinkingEndToken = '</thinking>';

/// Tag penutup XML yang diinjeksi guard.
const String kXmlThinkingEndTag = '</thinking>\n';

/// Daftar semua pembuka yang didukung.
const List<String> kThinkingOpenTokens = [
  kThinkingStartToken,
  kXmlThinkingStartToken,
];

/// Browser menuju token penutup yang cocok dengan pembuka tertentu.
String matchingCloseToken(String openToken) {
  return openToken == kXmlThinkingStartToken ? kXmlThinkingEndToken : kThinkingEndToken;
}

/// Tag penutup (lengkap, dengan newline) yang diinjeksi guard.
String matchingCloseTag(String openToken) {
  return openToken == kXmlThinkingStartToken ? kXmlThinkingEndTag : kThinkingEndTag;
}

/// Titik lokasi satu blok berpikir dalam teks.
class ThinkingSpan {
  const ThinkingSpan({
    required this.start,
    required this.open,
    required this.endIndex,
    required this.close,
  });

  /// Index token pembuka.
  final int start;

  /// Token pembuka yang terdeteksi (` thinking` / `<thinking>`).
  final String open;

  /// Index token penutup yang cocok, atau -1 bila belum tertutup.
  final int endIndex;

  /// Token penutup yang cocok.
  final String close;

  /// Index persis setelah token pembuka.
  int get startEnd => start + open.length;
}

/// Menemukan blok berpikir pertama (format literal ATAU XML).
/// Returns `null` bila tidak ada pembuka sama sekali.
ThinkingSpan? findThinkingSpan(String text) {
  int? bestStart;
  String? bestOpen;
  for (final open in kThinkingOpenTokens) {
    final i = text.indexOf(open);
    if (i >= 0 && (bestStart == null || i < bestStart)) {
      bestStart = i;
      bestOpen = open;
    }
  }
  if (bestStart == null || bestOpen == null) return null;
  final close = matchingCloseToken(bestOpen);
  final end = text.indexOf(close, bestStart + bestOpen.length);
  return ThinkingSpan(
    start: bestStart,
    open: bestOpen,
    endIndex: end,
    close: close,
  );
}

/// Mengambil konten antara pembuka dan penutup pada blok berpikir TERTUTUP.
/// Returns `null` bila tidak ada blok berpikir tertutup.
String? thinkingContent(String text) {
  final span = findThinkingSpan(text);
  if (span == null || span.endIndex < 0) return null;
  final raw = text.substring(span.startEnd, span.endIndex);
  final trimmed = raw.trim();
  return trimmed.isEmpty ? null : trimmed;
}

/// Versi "live" untuk streaming: konten blok berpikir meski tag penutup
/// belum muncul (berisi sisa yang sedang di-generate).
String? thinkingPreview(String text) {
  final span = findThinkingSpan(text);
  if (span == null) return null;
  final raw = text.substring(
    span.startEnd,
    span.endIndex < 0 ? text.length : span.endIndex,
  );
  final trimmed = raw.trim();
  return trimmed.isEmpty ? null : trimmed;
}

/// Teks jawaban final (konten setelah token penutup pertama).
/// Selama masih berada di dalam blok berpikir, mengembalikan string kosong.
String answerContent(String text) {
  final span = findThinkingSpan(text);
  if (span == null) return text;
  if (span.endIndex < 0) return '';
  return text.substring(span.endIndex + span.close.length).trim();
}

/// True bila aliran teks saat ini MASIH berada di dalam blok berpikir
/// (pembuka sudah tampil, penutup belum).
bool isInsideThinkingBlock(String text) {
  final span = findThinkingSpan(text);
  return span != null && span.endIndex < 0;
}

const List<String> _kPartialSuffixes = [
  '<|im_end',
  '<|im_start',
  '<|im_end_of_text',
  '<|endoftext',
  '</s',
];

/// Mencari akhiran token kontrol parsial yang menggantung di ujung `text`.
String? _trailingPartialSuffix(String text) {
  for (final suffix in _kPartialSuffixes) {
    if (text.endsWith(suffix)) return suffix;
  }
  return null;
}

/// Pola semua special token kontrol ChatML (Qwen/llama.cpp) — versi utuh
/// maupun TERPOTONG (partial), contoh `<|im_end|>`, `<|im_end`, `<|im_start`,
/// `<|im_end_of_text|>`, `<|endoftext`, `</s>`. `multiLine: true` supaya
/// alternatif `$` juga mencocokkan ujung baris (token parsial yang menggantung
/// di akhir aliran).
///
/// Urutan alternasi penting: `<|im_end_of_text|>` HARUS didahulukan sebelum
/// `<|im_end|>` karena yang terakhir juga cocok dengan prefiks `<|im_end`
/// dari token yang lebih panjang.
final RegExp kSpecialTokenRegExp = RegExp(
  r'<\|im_start\|>?|<\|im_end_of_text\|>?|<\|im_end\|>?|<\|endoftext\|>?|</s>|<\|[a-zA-Z_]*$',
  multiLine: true,
);

/// Membuang special token ChatML dari teks, baik yang utuh maupun terpotong.
///
/// Dua lapis pembersihan:
///   1. Regex menghapus token utuh (`<|im_end|>`, `</s>`) sekaligus versi
///      parsialnya (`<|im_end`, `<|im_start`, `<|endoftext`) di mana pun
///      berada — `>` bersifat opsional dan `$` menjangkau ujung baris/stream.
///   2. Sapuan akhir membuang tag kontrol parsial yang masih menggantung di
///      ujung teks (mis. `<|im_end`, `<|im_start`, `<|endoftext`, `</s`).
///
/// Whitespace di sekitar token dipertahankan supaya penggabungan per-piece
/// di ChatCubit tidak merusak spasi kata.
String stripSpecialTokens(String input) {
  var cleaned = input.replaceAll(kSpecialTokenRegExp, '');

  while (true) {
    final suffix = _trailingPartialSuffix(cleaned);
    if (suffix == null) break;
    final idx = cleaned.lastIndexOf(suffix);
    if (idx <= 0) {
      cleaned = '';
      break;
    }
    cleaned = cleaned.substring(0, idx);
  }
  return cleaned;
}

/// Pola blok berpikir KOSONG literal Qwen: ` thinking` langsung diikuti
/// ` response` dengan hanya whitespace di antaranya.
final RegExp kEmptyThinkingRegExp = RegExp(r' thinking\s*response');

/// Pola blok berpikir KOSONG format XML: `<thinking>\s*</thinking>`.
final RegExp kEmptyXmlThinkingRegExp = RegExp(
  r'<thinking>\s*</thinking>',
  multiLine: true,
);

/// Membuang blok reasoning KOSONG dari teks final model.
///
/// Berbeda dari [stripThinkingFromHistory] (yang membuang SEMUA blok berpikir
/// sebelum masuk context), fungsi ini hanya menyingkirkan blok yang tidak
/// berisi apa-apa — ` thinking  response` atau `<thinking> </thinking>` —
/// yang tersisa di teks jawaban streaming karena tag pembuka/penutup tiba di
/// piece terpisah. Blok berpikir berisi konten TIDAK disentuh (diproses oleh
/// guard/UI reasoning panel).
String removeEmptyThinkingBlocks(String text) {
  return text
      .replaceAll(kEmptyXmlThinkingRegExp, '')
      .replaceAll(kEmptyThinkingRegExp, '');
}