import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:logging/logging.dart';
import 'package:native_toolchain_c/native_toolchain_c.dart';

/// Lokasi amalgamasi sqlite-vec yang di-vendor, relatif terhadap root paket
/// ini. Sumber yang sama dipakai build CMake Android, Linux, dan Windows —
/// hook ini hanya mengompilasi ulangnya untuk target Apple.
const String _vec0SourcesDir = '../../android/app/src/main/cpp/vec0';

void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;

    // Android, Linux, dan Windows sudah menghasilkan libvec0.so / vec0.dll
    // lewat CMake aplikasi masing-masing; hook ini hanya melayani macOS & iOS
    // yang tidak punya build CMake sendiri.
    final targetOS = input.config.code.targetOS;
    if (targetOS != OS.macOS && targetOS != OS.iOS) return;

    final cbuilder = CBuilder.library(
      name: input.packageName,
      assetName: 'vec0_native_bindings_generated.dart',
      sources: [
        '$_vec0SourcesDir/sqlite-vec.c',
        'src/vec0_entry.c',
      ],
      includes: [_vec0SourcesDir],
    );
    await cbuilder.run(
      input: input,
      output: output,
      logger: Logger('vec0_native')
        ..level = Level.ALL
        ..onRecord.listen(
          // ignore: avoid_print // hook adalah program konsol, bukan UI Flutter
          (record) => print(record.message),
        ),
    );
  });
}
