// Copyright (c) 2026 Piergiorgio Vagnozzi
// Licensed under the MIT License.

import 'dart:typed_data';

import 'package:flutter_esptool/src/application/efuse_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('EfuseService.keyBlockWords', () {
    test('matches espefuse golden register words for 0x00..0x1f', () {
      final digest = Uint8List.fromList(List<int>.generate(32, (i) => i));
      final words = EfuseService.keyBlockWords(digest);

      // Captured from `espefuse --virt --chip esp32s3 burn_key BLOCK_KEY1`:
      //   PGM_DATA0..7  = 03020100 07060504 0b0a0908 0f0e0d0c
      //                   13121110 17161514 1b1a1918 1f1e1d1c
      //   CHECK_VALUE0..2 = 0d474ca0 03b2fc3f 13f4e9da
      expect(words, <int>[
        0x03020100, 0x07060504, 0x0b0a0908, 0x0f0e0d0c, //
        0x13121110, 0x17161514, 0x1b1a1918, 0x1f1e1d1c, //
        0x0d474ca0, 0x03b2fc3f, 0x13f4e9da, //
      ]);
    });

    test('produces 11 words (8 data + 3 RS)', () {
      final digest = Uint8List(32);
      expect(EfuseService.keyBlockWords(digest).length, 11);
    });

    test('rejects a digest that is not 32 bytes', () {
      expect(
        () => EfuseService.keyBlockWords(Uint8List(31)),
        throwsArgumentError,
      );
    });
  });

  group('EfuseService.flashEncryptionLockBlock0', () {
    test('sets KEY_PURPOSE_0=XTS_AES_128, WR_DIS and RD_DIS by default', () {
      final block0 = EfuseService.flashEncryptionLockBlock0();
      expect(block0.length, 8);
      // word2: KEY_PURPOSE_0 = 4 << 24
      expect(block0[2], 0x04 << 24);
      // word0: WR_DIS bit 8 (KEY_PURPOSE_0) | bit 23 (BLOCK_KEY0)
      expect(block0[0], (1 << 8) | (1 << 23));
      // word1: RD_DIS bit 0 (BLOCK_KEY0)
      expect(block0[1], 1 << 0);
      // no other words set
      expect(block0[3], 0);
      expect(block0.sublist(4), everyElement(0));
    });

    test('omits RD_DIS when readProtect is false', () {
      final block0 = EfuseService.flashEncryptionLockBlock0(readProtect: false);
      expect(block0[1], 0); // RD_DIS word untouched
      expect(block0[2], 0x04 << 24); // purpose still set
      expect(block0[0], (1 << 8) | (1 << 23)); // WR_DIS still set
    });

    test('key purpose constants match ESP32-S3 values', () {
      expect(EfuseService.keyPurposeXtsAes128, 4);
      expect(EfuseService.keyPurposeSecureBootDigest0, 9);
      expect(EfuseService.blockKey0, 4);
      expect(EfuseService.blockKey1, 5);
    });
  });
}
