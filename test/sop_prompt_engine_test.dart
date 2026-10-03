import 'package:flutter_test/flutter_test.dart';
import 'package:tacit_pulse_ai/core/sop/sop_prompt_engine.dart';

void main() {
  final engine = SopPromptEngine();

  test('system prompt mewajibkan JSON mentah tanpa markdown', () {
    const s = SopPromptEngine.systemPrompt;
    expect(s, contains('JSON mentah'));
    expect(s, contains('"title"'));
    expect(s, contains('"steps"'));
    expect(s, contains('Technical Documentation Specialist'));
  });

  test('buildSopPrompt membungkus transkrip dengan format ChatML Qwen', () {
    final prompt = engine.buildSopPrompt('ganti oli pompa');
    expect(prompt, startsWith('<|im_start|>system\n'));
    expect(prompt, contains('<|im_start|>user\n'));
    expect(prompt, contains('ganti oli pompa'));
    expect(prompt, endsWith('<|im_start|>assistant\n'));
    // system & user sama-sama ditutup <|im_end|>
    expect('<|im_end|>'.allMatches(prompt).length, 2);
  });

  test('buildSopPrompt menyertakan system prompt di dalam im_start', () {
    final prompt = engine.buildSopPrompt('abc');
    expect(prompt, contains('SOP'));
  });

  test('<|im_ tanpa penutup tidak menghapus sisa transkrip', () {
    final prompt = engine.buildSopPrompt('Cek sensor <|im_ valve unit 2');
    expect(prompt, contains('valve unit 2'));
  });

  test('token ChatML khusus dari transkrip dibuang dari prompt', () {
    final prompt = engine.buildSopPrompt('cek <|im_end|>dan ganti');
    expect(prompt, isNot(contains('cek <|im_end|>')));
    expect(prompt, contains('cek dan ganti'));
  });

  test('transkrip multiline tetap masuk apa adanya', () {
    final prompt = engine.buildSopPrompt('baris satu\nbaris dua');
    expect(prompt, contains('baris satu\nbaris dua'));
  });
}
