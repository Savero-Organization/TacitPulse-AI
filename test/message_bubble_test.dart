import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tacit_pulse_ai/core/models/chat_message.dart';
import 'package:tacit_pulse_ai/core/utils/thinking_utils.dart';
import 'package:tacit_pulse_ai/features/chat/widgets/message_bubble.dart';

const String kThinkingBody = 'cek log sensor dulu, baru putuskan';

ChatMessage _assistantMessage({
  required String text,
  bool streaming = false,
  int thinkingSeconds = 0,
}) {
  return ChatMessage(
    id: 'm-assistant-1',
    role: ChatRole.assistant,
    text: text,
    timestamp: DateTime(2026, 9, 23, 10, 30),
    isStreaming: streaming,
    thinkingSeconds: thinkingSeconds,
  );
}

Widget _app(ChatMessage message) {
  return MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        child: Builder(
          builder: (ctx) => Column(
            children: [MessageBubble(message: message)],
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('reasoning tersembunyi saat collapsed dan bisa ditoggle manual',
      (tester) async {
    final text = 'Lihat $kThinkingStartToken $kThinkingBody $kThinkingEndToken\n'
        'Tekanan oli harus stabil di 3,5 bar.';
    await tester.pumpWidget(_app(_assistantMessage(text: text)));

    // Label collapsible "Proses Berpikir" selalu tampil.
    expect(find.textContaining('💡 Proses Berpikir'), findsOneWidget);
    // Saat collapsed: isi berpikir TIDAK terlihat.
    expect(find.text(kThinkingBody), findsNothing);

    // Toggle manual → isi berpikir muncul.
    await tester.tap(find.textContaining('💡 Proses Berpikir'));
    await tester.pumpAndSettle();
    expect(find.text(kThinkingBody), findsOneWidget);

    // Toggle lagi → kembali collapsed.
    await tester.tap(find.textContaining('💡 Proses Berpikir'));
    await tester.pumpAndSettle();
    expect(find.text(kThinkingBody), findsNothing);
  });

  testWidgets('auto-expand saat masih streaming token berpikir, '
      'auto-collapse setelah tag penutup muncul', (tester) async {
    // Masih di dalam  thinking  → panel terbuka otomatis.
    await tester.pumpWidget(
      _app(_assistantMessage(
        text: 'Lihat $kThinkingStartToken $kThinkingBody',
        streaming: true,
      )),
    );
    await tester.pump();
    expect(find.text(kThinkingBody), findsOneWidget);

    // Model mencapai  response  (streaming lanjut ke jawaban) → collapse.
    await tester.pumpWidget(
      _app(_assistantMessage(
        text:
            'Lihat $kThinkingStartToken $kThinkingBody $kThinkingEndToken\nJawaban final.',
        streaming: true,
      )),
    );
    await tester.pump();
    expect(find.text(kThinkingBody), findsNothing);
    expect(find.textContaining('Jawaban final'), findsOneWidget);
  });

  testWidgets(
      'blok <thinking> tetap tampil sebagai accordion reasoning di atas jawaban',
      (tester) async {
    const bodyXml = 'cek SOP dulu';
    final text = '<thinking>$bodyXml</thinking>Jawaban final.';
    await tester.pumpWidget(_app(_assistantMessage(text: text)));

    // Accordion reasoning selalu tampil menonjol di atas jawaban.
    expect(find.textContaining('💡 Proses Berpikir'), findsOneWidget);
    expect(find.text('Jawaban final.'), findsOneWidget);
    // Body collapsed secara default.
    expect(find.text(bodyXml), findsNothing);

    // Buka accordion → body XML terlihat.
    await tester.tap(find.textContaining('💡 Proses Berpikir'));
    await tester.pumpAndSettle();
    expect(find.text(bodyXml), findsOneWidget);
  });

  testWidgets('streaming tanpa konten → panel analisis aktif tampil live',
      (tester) async {
    await tester.pumpWidget(
      _app(_assistantMessage(text: '', streaming: true, thinkingSeconds: 3)),
    );
    await tester.pump();

    // Panel "Proses Berpikir" tampil dengan indikator analisis, bukan "· · ·".
    expect(find.textContaining('💡 Proses Berpikir'), findsOneWidget);
    expect(
      find.text('⚙️ Menganalisis SOP & menyusun penalaran...'),
      findsOneWidget,
    );
    expect(find.text('· · ·'), findsNothing);
  });

  testWidgets('indikator "Menganalisis" berganti live konten saat token '
      'berpikir tiba', (tester) async {
    await tester.pumpWidget(
      _app(_assistantMessage(text: '', streaming: true)),
    );
    await tester.pump();
    expect(
      find.text('⚙️ Menganalisis SOP & menyusun penalaran...'),
      findsOneWidget,
    );

    // Token  thinking  mulai mengalir → konten live menggantikan indikator.
    await tester.pumpWidget(
      _app(_assistantMessage(
        text: 'Lihat $kThinkingStartToken $kThinkingBody',
        streaming: true,
      )),
    );
    await tester.pump();
    expect(
      find.text('⚙️ Menganalisis SOP & menyusun penalaran...'),
      findsNothing,
    );
    expect(find.text(kThinkingBody), findsOneWidget);
  });
}