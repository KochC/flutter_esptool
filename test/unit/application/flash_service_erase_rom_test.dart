import 'dart:typed_data';

import 'package:flutter_esptool/flutter_esptool.dart';
import 'package:flutter_test/flutter_test.dart';

/// Records the opcodes sent and answers every command with success.
class _RecordingTransport implements EspTransportInterface {
  _RecordingTransport({this.failOpcode});

  final EspCommandOpcode? failOpcode;
  final opcodes = <EspCommandOpcode>[];

  @override
  bool get isOpen => true;

  @override
  Future<void> open(EspConfig config) async {}

  @override
  Future<void> close() async {}

  @override
  Future<void> changeBaud(int newBaud) async {}

  @override
  Future<void> resetToBootloader() async {}

  @override
  Future<void> hardReset() async {}

  @override
  Future<List<int>> readRaw(int count, {Duration? timeout}) async => <int>[];

  @override
  Future<void> flushRx() async {}

  @override
  Future<void> writeRaw(List<int> bytes, {Duration? timeout}) async {}

  @override
  Future<void> reopenPort({
    Duration waitBefore = const Duration(milliseconds: 1500),
  }) async {}

  @override
  Future<EspResponse> sendCommand(
    EspCommand command, {
    Duration? timeout,
  }) async {
    opcodes.add(command.opcode);
    return EspResponse(
      opcode: command.opcode,
      value: 0,
      data: Uint8List(0),
      status: command.opcode == failOpcode ? 1 : 0,
      error: 0,
    );
  }

  int count(EspCommandOpcode op) => opcodes.where((o) => o == op).length;
}

void main() {
  group('FlashService.eraseRegionRom + writeFlash on one ROM connection', () {
    test(
        'SPI_ATTACH is sent once: the writes after the erase must not '
        're-attach (the ESP32-S2 ROM stops responding after FLASH_END(1))',
        () async {
      final t = _RecordingTransport();
      final flash = FlashService(transport: t, blockSize: 0x400);

      final erased = await flash.eraseRegionRom(offset: 0, eraseSize: 0x2000);
      expect(erased.isSuccess, isTrue);
      final written = await flash.writeFlash(
        FlashParameters(
          offset: 0x1000,
          data: Uint8List(0x400),
          leaveInDownloadMode: true,
        ),
      );
      expect(written.isSuccess, isTrue);

      expect(t.count(EspCommandOpcode.spiAttach), 1);
      expect(t.opcodes.first, EspCommandOpcode.spiAttach);
    });

    test(
        'the erase sends no FLASH_END: the next FLASH_BEGIN follows the last '
        'erase block directly (FLASH_END(1) then FLASH_BEGIN stalls the '
        'ESP32-S2 ROM)', () async {
      final t = _RecordingTransport();
      final flash = FlashService(transport: t, blockSize: 0x400);
      await flash.eraseRegionRom(offset: 0, eraseSize: 0x1000);
      expect(t.count(EspCommandOpcode.flashEnd), 0);
      await flash.writeFlash(
        FlashParameters(
          offset: 0,
          data: Uint8List(0x400),
          leaveInDownloadMode: true,
        ),
      );
      final begins = [
        for (var i = 0; i < t.opcodes.length; i++)
          if (t.opcodes[i] == EspCommandOpcode.flashBegin) i,
      ];
      expect(begins, hasLength(2));
      expect(t.opcodes[begins[1] - 1], EspCommandOpcode.flashData);
      expect(t.count(EspCommandOpcode.flashEnd), 0);
    });

    test('a second erase on the same connection does not re-attach', () async {
      final t = _RecordingTransport();
      final flash = FlashService(transport: t, blockSize: 0x400);
      await flash.eraseRegionRom(offset: 0, eraseSize: 0x1000);
      await flash.eraseRegionRom(offset: 0x1000, eraseSize: 0x1000);
      expect(t.count(EspCommandOpcode.spiAttach), 1);
    });

    test('after resetSpiAttachState (reconnect) the erase attaches again',
        () async {
      final t = _RecordingTransport();
      final flash = FlashService(transport: t, blockSize: 0x400);
      await flash.eraseRegionRom(offset: 0, eraseSize: 0x1000);
      flash.resetSpiAttachState();
      await flash.eraseRegionRom(offset: 0, eraseSize: 0x1000);
      expect(t.count(EspCommandOpcode.spiAttach), 2);
    });

    test('a rejected attach fails the erase and is retried next time',
        () async {
      final t = _RecordingTransport(failOpcode: EspCommandOpcode.spiAttach);
      final flash = FlashService(transport: t, blockSize: 0x400);
      final r = await flash.eraseRegionRom(offset: 0, eraseSize: 0x1000);
      expect(r.isSuccess, isFalse);
      await flash.eraseRegionRom(offset: 0, eraseSize: 0x1000);
      expect(t.count(EspCommandOpcode.spiAttach), 2);
    });
  });
}
