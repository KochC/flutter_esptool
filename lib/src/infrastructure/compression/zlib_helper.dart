// Copyright (c) 2026 Piergiorgio Vagnozzi
// Licensed under the MIT License.

import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_esptool/src/models/esp_error.dart';
import 'package:flutter_esptool/src/models/esp_result.dart';

/// Wraps zlib compression and decompression helpers.
class ZlibHelper {
  /// Compresses [data] with zlib (synchronous).
  ///
  /// For large payloads prefer [compressAsync] to avoid blocking the UI isolate.
  static Result<Uint8List> compress(Uint8List data) {
    try {
      final compressed = ZLibCodec().encode(data);
      return Success<Uint8List>(Uint8List.fromList(compressed));
    } catch (error, stackTrace) {
      // coverage:ignore-start
      // ZLibCodec.encode(Uint8List) has no practical invalid input; this keeps
      // the public Result API defensive if the runtime codec throws.
      return Failure<Uint8List>(
        EspError(
          type: EspErrorType.compressionError,
          message: error.toString(),
          stackTrace: stackTrace,
        ),
      );
      // coverage:ignore-end
    }
  }

  /// Compresses [data] with zlib off the calling isolate.
  ///
  /// Runs [ZLibCodec.encode] in a helper isolate so the Flutter UI isolate
  /// stays responsive for large payloads.
  static Future<Result<Uint8List>> compressAsync(Uint8List data) async {
    try {
      final compressed = await Isolate.run(
        () => Uint8List.fromList(ZLibCodec().encode(data)),
      );
      return Success<Uint8List>(compressed);
    } catch (error, stackTrace) {
      return Failure<Uint8List>(
        EspError(
          type: EspErrorType.compressionError,
          message: error.toString(),
          stackTrace: stackTrace,
        ),
      );
    }
  }

  /// Decompresses zlib [data] (synchronous).
  ///
  /// For large payloads prefer [decompressAsync] to avoid blocking the UI isolate.
  static Result<Uint8List> decompress(Uint8List data) {
    try {
      final decompressed = ZLibCodec().decode(data);
      return Success<Uint8List>(Uint8List.fromList(decompressed));
    } catch (error, stackTrace) {
      return Failure<Uint8List>(
        EspError(
          type: EspErrorType.compressionError,
          message: error.toString(),
          stackTrace: stackTrace,
        ),
      );
    }
  }

  /// Decompresses zlib [data] off the calling isolate.
  ///
  /// Runs [ZLibCodec.decode] in a helper isolate so the Flutter UI isolate
  /// stays responsive for large payloads.
  static Future<Result<Uint8List>> decompressAsync(Uint8List data) async {
    try {
      final decompressed = await Isolate.run(
        () => Uint8List.fromList(ZLibCodec().decode(data)),
      );
      return Success<Uint8List>(decompressed);
    } catch (error, stackTrace) {
      return Failure<Uint8List>(
        EspError(
          type: EspErrorType.compressionError,
          message: error.toString(),
          stackTrace: stackTrace,
        ),
      );
    }
  }
}
