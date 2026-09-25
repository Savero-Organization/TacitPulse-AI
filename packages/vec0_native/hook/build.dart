import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:logging/logging.dart';
import 'package:native_toolchain_c/native_toolchain_c.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;

    // Android, Linux, dan Windows sudah menghasilkan libvec0.so / vec0.dll
    // lewat CMake aplikasi masing-masing; hook ini hanya melayani macOS & iOS
    // yang tidak punya build CMake sendiri.
    final targetOS = input.config.code.targetOS;
    if (targetOS != OS.macOS && targetOS != OS.iOS) return;

    // Amalgamasi sqlite-vec di-vendor sekali di paket app (source of
    // truth yang sama untuk build CMake Android, Linux, dan Windows);
    // hook ini hanya mengompilasi ulangnya untuk target Apple. Path
    // dihitung dari input.packageRoot (anchor resmi hook runner, bukan
    // cwd) lalu divalidasi dulu — bila struktur repo berubah, errornya
    // jelas dan muncul di hook, bukan "file not found" dari compiler.
    final packageRoot = input.packageRoot.toFilePath();
    final vec0SourcesDir = '$packageRoot/../../android/app/src/main/cpp/vec0';
    final sqliteVecSource = '$vec0SourcesDir/sqlite-vec.c';
    final entrySource = '$packageRoot/src/vec0_entry.c';
    if (!File(sqliteVecSource).existsSync()) {
      throw StateError(
        'Amalgamasi sqlite-vec tidak ditemukan: $sqliteVecSource — '
        'struktur repo berubah? Perbarui path di '
        'packages/vec0_native/hook/build.dart.',
      );
    }
    if (!File(entrySource).existsSync()) {
      throw StateError(
        'Trampoline vec0_entry.c tidak ditemukan: $entrySource — '
        'paket vec0_native tidak lengkap.',
      );
    }

    final cbuilder = CBuilder.library(
      name: input.packageName,
      assetName: 'vec0_native_bindings_generated.dart',
      sources: [
        sqliteVecSource,
        entrySource,
      ],
      includes: [vec0SourcesDir],
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
