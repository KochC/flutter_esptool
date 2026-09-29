// Copyright (c) 2026 Piergiorgio Vagnozzi
// Licensed under the MIT License.

import 'dart:typed_data';

import 'package:flutter_esptool/src/domain/flash/flash_parameters.dart';
import 'package:flutter_esptool/src/models/esp_result.dart';

/// Describes flash operations supported by the package.
abstract interface class FlashServiceInterface {
  /// Writes a flash image using [params].
  Future<Result<void>> writeFlash(FlashParameters params);

  /// Reads flash bytes using [params].
  Future<Result<Uint8List>> readFlash(FlashReadParameters params);

  /// Erases flash, optionally scoped to [offset] and [size].
  Future<Result<void>> eraseFlash({int? offset, int? size});

  /// Erases a flash region using the ROM bootloader FLASH_BEGIN erase path.
  ///
  /// Sends FLASH_BEGIN for [eraseSize] bytes at [offset] and writes 0xFF
  /// blocks over the whole region (the ROM has no erase opcode; 0xD0/0xD1
  /// are stub-only). Sends no FLASH_END — the next FLASH_BEGIN on the same
  /// connection finalises it. [eraseSize] must be a multiple of 4096.
  /// [onProgress] receives the completed fraction (0.0–1.0) after each
  /// block; a full ROM erase takes minutes.
  Future<Result<void>> eraseRegionRom({
    required int offset,
    required int eraseSize,
    void Function(double fraction)? onProgress,
  });

  /// Computes the device MD5 for the flash range.
  Future<Result<String>> md5Flash(int offset, int size);
}
