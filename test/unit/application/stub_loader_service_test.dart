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

    // The exact USB-Serial/JTAG watchdog sequence per chip, as esptool's
    // disable_watchdogs() (esptool/targets/esp32c3.py) issues it with each
    // target's registers: RWDT unlock/disable/lock, then SWD unlock,
    // read-modify-write of the auto-feed bit, lock.
    for (final (
          chip,
          bufNo,
          wdtCfg0,
          wdtProt,
          swdConf,
          swdFeed,
          swdProt,
          swdKey
        ) in [
      (
        ChipFamily.esp32s3,
        0x3FCEF14C,
        0x60008098,
        0x600080B0,
        0x600080B4,
        1 << 31,
        0x600080B8,
        0x8F1D312A,
      ),
      (
        ChipFamily.esp32c6,
        0x4087F580,
        0x600B1C00,
        0x600B1C18,
        0x600B1C1C,
        1 << 18,
        0x600B1C20,
        0x50D83AA1,
      ),
    ]) {
      test('$chip on USB-JTAG disables its own watchdog registers', () async {
        const swdConfBefore = 0x00000123;
        final transport = FakeTransport(
          onCommand: (command) {
            if (command.opcode == EspCommandOpcode.readReg) {
              final addr = ByteData.sublistView(command.data)
                  .getUint32(0, Endian.little);
              if (addr == bufNo) return okResponse(command.opcode, value: 3);
              if (addr == swdConf) {
                return okResponse(command.opcode, value: swdConfBefore);
              }
              return okResponse(command.opcode, value: 0xBAD);
            }
            return okResponse(command.opcode);
          },
          readRawBytes: <int>[0x4F, 0x48, 0x41, 0x49],
        );

        final result =
            await StubLoaderService(transport: transport).loadStub(chip);
        expect(result.isSuccess, isTrue);

        int field(EspCommand c, int at) =>
            ByteData.sublistView(c.data).getUint32(at, Endian.little);
        final regOps = transport.sentCommands
            .where((c) =>
                c.opcode == EspCommandOpcode.readReg ||
                c.opcode == EspCommandOpcode.writeReg)
            .map((c) => c.opcode == EspCommandOpcode.readReg
                ? ('r', field(c, 0), null)
                : ('w', field(c, 0), field(c, 4)))
            .toList();
        expect(regOps, [
          ('r', bufNo, null),
          ('w', wdtProt, 0x50D83AA1),
          ('w', wdtCfg0, 0),
          ('w', wdtProt, 0),
          ('w', swdProt, swdKey),
          ('r', swdConf, null),
          ('w', swdConf, swdConfBefore | swdFeed),
          ('w', swdProt, 0),
        ]);
        // All of it happens before the stub upload starts.
        final firstBegin = transport.sentCommands
            .indexWhere((c) => c.opcode == EspCommandOpcode.memBegin);
        final lastReg = transport.sentCommands
            .lastIndexWhere((c) => c.opcode == EspCommandOpcode.writeReg);
        expect(lastReg, lessThan(firstBegin));
      });
    }

    test('ESP32-C6 not on USB-JTAG: probes the port, writes no register',
        () async {
      final transport = FakeTransport(
        onCommand: (command) => command.opcode == EspCommandOpcode.readReg
            ? okResponse(command.opcode, value: 0) // UART0
            : okResponse(command.opcode),
        readRawBytes: <int>[0x4F, 0x48, 0x41, 0x49],
      );
      final result = await StubLoaderService(transport: transport)
          .loadStub(ChipFamily.esp32c6);
      expect(result.isSuccess, isTrue);
      final ops = transport.sentCommands.map((c) => c.opcode).toList();
      expect(ops.where((o) => o == EspCommandOpcode.readReg), hasLength(1));
      expect(ops, isNot(contains(EspCommandOpcode.writeReg)));
    });

    test(
        'ESP32-C6: uploads its own stub in 0x1800 blocks at its RAM '
        'addresses and jumps to the C6 entry', () async {
      final transport = FakeTransport(
        readRawBytes: <int>[0xC0, 0x4F, 0x48, 0x41, 0x49, 0xC0],
      );
      final service = StubLoaderService(transport: transport);

      final result = await service.loadStub(ChipFamily.esp32c6);
      expect(result.isSuccess, isTrue);
      expect(service.isLoaded, isTrue);

      final begins = transport.sentCommands
          .where((c) => c.opcode == EspCommandOpcode.memBegin)
          .map((c) => ByteData.sublistView(c.data))
          .toList();
      expect(begins, hasLength(2)); // text + data
      for (final b in begins) {
        expect(b.getUint32(8, Endian.little), 0x1800); // block size
      }
      expect(begins[0].getUint32(0, Endian.little), 6404);
      expect(begins[0].getUint32(12, Endian.little), 0x40800000);
      expect(begins[1].getUint32(0, Endian.little), 192);
      expect(begins[1].getUint32(12, Endian.little), 0x40852D64);
      final end = ByteData.sublistView(transport.sentCommands
          .lastWhere((c) => c.opcode == EspCommandOpcode.memEnd)
          .data);
      expect(end.getUint32(0, Endian.little), 0); // 0 = jump to entry
      expect(end.getUint32(4, Endian.little), 0x40800000);
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
      (
        ChipFamily.esp32c6,
        '2026ea3d4f65af9017e1da5341698d077f7b9a2e1837c286b5cba6d300dbcfcf',
        'aa0d4f8be6244247f807ac329c05478fa0599bf18b680cb6609faf43aa009667',
        0x40800000,
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
