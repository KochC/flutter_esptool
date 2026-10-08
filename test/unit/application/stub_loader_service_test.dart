// Copyright (c) 2026 Piergiorgio Vagnozzi
// Licensed under the MIT License.

import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_esptool/flutter_esptool.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_transport.dart';

/// The bytes uploaded per MEM_BEGIN segment, reassembled from MEM_DATA.
List<Uint8List> _uploadedSegments(FakeTransport t) {
  final segments = <BytesBuilder>[];
  for (final c in t.sentCommands) {
    if (c.opcode == EspCommandOpcode.memBegin) {
      segments.add(BytesBuilder());
    } else if (c.opcode == EspCommandOpcode.memData) {
      segments.last.add(c.data.sublist(16));
    }
  }
  return [for (final b in segments) b.toBytes()];
}

int _entry(FakeTransport t) => ByteData.sublistView(
      t.sentCommands.lastWhere((c) => c.opcode == EspCommandOpcode.memEnd).data,
    ).getUint32(4, Endian.little);

void main() {
  group('StubLoaderService.loadStub', () {
    test('rejects a family without a stub', () async {
      final service = StubLoaderService(transport: FakeTransport());
      final result = await service.loadStub(ChipFamily.esp32);
      expect(result.isFailure, isTrue);
      expect(
        (result as Failure<void>).error.type,
        EspErrorType.stubNotAvailable,
      );
      expect(service.isLoaded, isFalse);
    });

    test('uploads the stub and succeeds when OHAI is received', () async {
      // OHAI SLIP frame: C0 'O' 'H' 'A' 'I' C0.
      final transport = FakeTransport(
        readRawBytes: <int>[0xC0, 0x4F, 0x48, 0x41, 0x49, 0xC0],
      );
      final service = StubLoaderService(transport: transport);

      final result = await service.loadStub(ChipFamily.esp32s3);
      expect(result.isSuccess, isTrue);
      expect(service.isLoaded, isTrue);

      // Verify the upload actually issued MEM_BEGIN + MEM_DATA + MEM_END.
      final opcodes = transport.sentCommands.map((c) => c.opcode).toSet();
      expect(opcodes, contains(EspCommandOpcode.memBegin));
      expect(opcodes, contains(EspCommandOpcode.memData));
      expect(opcodes, contains(EspCommandOpcode.memEnd));
    });

    test('fails when the stub never sends OHAI', () async {
      // readRaw returns nothing → OHAI reader times out.
      final transport = FakeTransport();
      final service = StubLoaderService(transport: transport);

      final result = await service.loadStub(ChipFamily.esp32s3);
      expect(result.isFailure, isTrue);
      expect(
        (result as Failure<void>).error.type,
        EspErrorType.stubNotAvailable,
      );
      expect(service.isLoaded, isFalse);
    }, timeout: const Timeout(Duration(seconds: 20)));

    test('watchdog disable runs when USB-JTAG is detected', () async {
      // UARTDEV_BUF_NO read must return the USB-JTAG marker (3) so the WDT
      // disable branch executes; all writes succeed; OHAI is provided.
      final transport = FakeTransport(
        onCommand: (command) {
          if (command.opcode == EspCommandOpcode.readReg) {
            return okResponse(command.opcode, value: 3); // USB-JTAG/Serial
          }
          return okResponse(command.opcode);
        },
        readRawBytes: <int>[0x4F, 0x48, 0x41, 0x49],
      );
      final service = StubLoaderService(transport: transport);

      final result = await service.loadStub(ChipFamily.esp32s3);
      expect(result.isSuccess, isTrue);
    });

    test('surfaces a MEM_BEGIN failure during upload', () async {
      final transport = FakeTransport(
        failOpcodes: {EspCommandOpcode.memBegin},
      );
      final service = StubLoaderService(transport: transport);

      final result = await service.loadStub(ChipFamily.esp32s3);
      expect(result.isFailure, isTrue);
      expect(service.isLoaded, isFalse);
    });

    test(
        'ESP32-S2: uploads its own stub in 0x800 blocks, skips the S3 '
        'watchdog steps, jumps to the S2 entry', () async {
      final transport = FakeTransport(
        readRawBytes: <int>[0xC0, 0x4F, 0x48, 0x41, 0x49, 0xC0],
      );
      final service = StubLoaderService(transport: transport);

      final result = await service.loadStub(ChipFamily.esp32s2);
      expect(result.isSuccess, isTrue);
      expect(service.isLoaded, isTrue);

      final ops = transport.sentCommands.map((c) => c.opcode).toList();
      // No UARTDEV_BUF_NO read / RTC-WDT writes (ESP32-S3 only).
      expect(ops, isNot(contains(EspCommandOpcode.readReg)));
      expect(ops, isNot(contains(EspCommandOpcode.writeReg)));

      final begins = transport.sentCommands
          .where((c) => c.opcode == EspCommandOpcode.memBegin)
          .map((c) => ByteData.sublistView(c.data))
          .toList();
      expect(begins, hasLength(2)); // text + data
      for (final b in begins) {
        expect(b.getUint32(8, Endian.little), 0x800); // block size
      }
      expect(begins.first.getUint32(12, Endian.little), 0x40028000);
      for (final c in transport.sentCommands
          .where((c) => c.opcode == EspCommandOpcode.memData)) {
        expect(c.data.length - 16, lessThanOrEqualTo(0x800));
      }
      final end = transport.sentCommands
          .lastWhere((c) => c.opcode == EspCommandOpcode.memEnd);
      expect(ByteData.sublistView(end.data).getUint32(4, Endian.little),
          0x4002800C);
    });

    test('ESP32-S3 keeps 0x1800 blocks', () async {
      final transport = FakeTransport(
        readRawBytes: <int>[0x4F, 0x48, 0x41, 0x49],
      );
      await StubLoaderService(transport: transport)
          .loadStub(ChipFamily.esp32s3);
      final begin = transport.sentCommands
          .firstWhere((c) => c.opcode == EspCommandOpcode.memBegin);
      expect(
          ByteData.sublistView(begin.data).getUint32(8, Endian.little), 0x1800);
    });

    // Provenance pins (third_party/esp-flasher-stub/README.md): the embedded
    // stubs must stay esp-flasher-stub v0.7.0 (MIT OR Apache-2.0) — never
    // the GPL legacy stub from esptool's stub_flasher/1/.
    for (final (chip, text, data, entry) in [
      (
        ChipFamily.esp32s3,
        '911d584127cbbecef6661d60aa0ff97357add29153fff10d98e700fb76f05b71',
        'd02b76d857480cec0f861ef353009551feb7574deffca599cc1ea9d0758103f0',
        0x4037800C,
      ),
      (
        ChipFamily.esp32s2,
        'f038186b9984b8767654ef1bd8da8d1b9db939762f2cb07a5854dcf0c1f8909f',
        'a8897efc120fd1c7e74f439c3b8aea3488c84995c0ca2c514c2a5c25c78b6c9d',
        0x4002800C,
      ),
    ]) {
      test('$chip uploads the pinned esp-flasher-stub v0.7.0 binary', () async {
        final transport = FakeTransport(
          readRawBytes: <int>[0xC0, 0x4F, 0x48, 0x41, 0x49, 0xC0],
        );
        final result =
            await StubLoaderService(transport: transport).loadStub(chip);
        expect(result.isSuccess, isTrue);
        final segments = _uploadedSegments(transport);
        expect(segments, hasLength(2));
        expect(sha256.convert(segments[0]).toString(), text);
        expect(sha256.convert(segments[1]).toString(), data);
        expect(_entry(transport), entry);
      });
    }
  });
}
