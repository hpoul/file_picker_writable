// Bindings to the fd shim (src/fpw_fd.c), built as a code asset by
// hook/build.dart. Non-leaf on purpose: a cold-storage read can block,
// which a leaf call must not (doc/large-file-reads-plan.md §5).

// The names are the C symbols, as @Native resolves them.
// ignore_for_file: non_constant_identifier_names

import 'dart:ffi';

/// The shim's cleanup record {fd, buffer}.
final class FpwReader extends Opaque {}

@Native<Pointer<FpwReader> Function(Int32, Int64)>()
external Pointer<FpwReader> fpw_reader_new(int fd, int bufferLength);

@Native<Pointer<Uint8> Function(Pointer<FpwReader>)>()
external Pointer<Uint8> fpw_reader_buffer(Pointer<FpwReader> reader);

@Native<Int64 Function(Pointer<FpwReader>, Int64, Int64)>()
external int fpw_pread_full(Pointer<FpwReader> reader, int offset, int length);

@Native<Int64 Function(Pointer<FpwReader>, Int64)>()
external int fpw_read_full(Pointer<FpwReader> reader, int length);

@Native<Int32 Function(Int32)>()
external int fpw_close(int fd);

@Native<Int32 Function(Pointer<FpwReader>)>()
external int fpw_reader_close(Pointer<FpwReader> reader);

@Native<Void Function(Pointer<Void>)>()
external void fpw_reader_finalize(Pointer<Void> reader);
