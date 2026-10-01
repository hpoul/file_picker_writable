import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:native_toolchain_c/native_toolchain_c.dart';

/// Builds the fd shim (src/fpw_fd.c, doc/large-file-reads-plan.md §5) as a
/// code asset for every target the app builds for, including the host for
/// `flutter test`, so the byte path needs no podspec or CMake step.
///
/// Except Windows: the shim is POSIX C, and openRead throws
/// UnsupportedError there before any binding is touched, so a Windows app
/// (or `flutter test` on a Windows host) builds without it.
void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) {
      return;
    }
    if (input.config.code.targetOS == OS.windows) {
      return;
    }
    await CBuilder.library(
      name: 'fpw_fd',
      assetName: 'src/fd_native.dart',
      sources: ['src/fpw_fd.c'],
    ).run(input: input, output: output);
  });
}
