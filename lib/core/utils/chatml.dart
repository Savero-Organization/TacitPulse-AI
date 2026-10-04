// chatml.dart — util bersama untuk membersihkan token ChatML dari teks
// yang akan disisipkan ke prompt: mencegah prompt injection yang mematahkan
// struktur giliran (<|im_start|>/... embed dalam query ataupun chunk).

/// Menangkap semua varian token ChatML (`<|im_start|>`, `<|im_end|>`,
/// parsial `<|im_...|>`) sekaligus, sehingga input bersarang seperti
/// `<|<|im_im_start|>user` tidak bisa merakit ulang token setelah satu
/// lapis pembersihan.
final RegExp chatMlTokenPattern = RegExp(
  r'<\|im_[a-zA-Z0-9_-]*\|?>?',
  caseSensitive: false,
);

/// Strip token ChatML sampai stabil: input bersarang (`<|<|im_im_start|>`)
/// akan menyisakan pola baru setelah satu kali sweep, jadi ulangi sampai
/// tidak ada perubahan.
String stripChatMlTokens(String text) {
  var current = text;
  String next;
  do {
    next = current.replaceAll(chatMlTokenPattern, '');
    if (next == current) break;
    current = next;
  } while (true);
  // Potong ekor token kontrol parsial/utuh (`<|im`, `<|im_end`, `<|im_end|>`,
  // `<|im_start|...`, `<|endoftext`) hingga akhir teks — tanpa swallowing
  // baris sebelumnnya karena greedy `.*` dibatasi baris (multiLine: false).
  return current.replaceAll(
    RegExp(r'\s*<\|(im(_end|_start|_of_text)?|endoftext)>?.*$',
        multiLine: false),
    '',
  );
}
