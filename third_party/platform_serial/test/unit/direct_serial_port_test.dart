import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:platform_serial/platform_serial.dart';

class MockSerialPlatformInterface extends Mock
    implements SerialPlatformInterface {}

void main() {
  const config = SerialConfig(portName: '/dev/cu.test');
  late MockSerialPlatformInterface platform;
  late DirectSerialPort port;

  setUpAll(() {
    registerFallbackValue(config);
    registerFallbackValue(Uint8List(0));
  });

  setUp(() async {
    platform = MockSerialPlatformInterface();
    when(() => platform.openPort(any())).thenAnswer((_) async {});
    when(() => platform.closePort(any())).thenAnswer((_) async {});
    port = DirectSerialPort(platform: platform);
    await port.open(config);
  });

  Matcher serialError(SerialErrorType type) =>
      isA<SerialError>().having((e) => e.type, 'type', type);

  test('returns the platform read', () async {
    when(() => platform.readData(any(), any()))
        .thenAnswer((_) async => Uint8List.fromList([1, 2]));
    expect(await port.read(1), [1, 2]);
    verify(() => platform.readData('/dev/cu.test', 1)).called(1);
  });

  test(
      'a timed-out read is resumed by the next read instead of being '
      'raced: its bytes are not lost', () async {
    final late = Completer<Uint8List>();
    when(() => platform.readData(any(), any())).thenAnswer((_) => late.future);

    await expectLater(
      port.read(1, timeout: const Duration(milliseconds: 5)),
      throwsA(serialError(SerialErrorType.timeout)),
    );
    // The erase reply arrives while no one is reading.
    late.complete(Uint8List.fromList([0xC0, 0x01, 0xD0]));

    expect(await port.read(1), [0xC0, 0x01, 0xD0]);
    // Only ONE platform read was ever started — no competing second loop.
    verify(() => platform.readData(any(), any())).called(1);

    // Once delivered, the next read starts a fresh platform read.
    when(() => platform.readData(any(), any()))
        .thenAnswer((_) async => Uint8List.fromList([7]));
    expect(await port.read(1), [7]);
  });

  test('a resumed read that is still pending can time out again', () async {
    final late = Completer<Uint8List>();
    when(() => platform.readData(any(), any())).thenAnswer((_) => late.future);
    for (var i = 0; i < 2; i++) {
      await expectLater(
        port.read(1, timeout: const Duration(milliseconds: 5)),
        throwsA(serialError(SerialErrorType.timeout)),
      );
    }
    late.complete(Uint8List.fromList([9]));
    expect(await port.read(1), [9]);
    verify(() => platform.readData(any(), any())).called(1);
  });

  test('an error of the pending read reaches the next caller once', () async {
    final late = Completer<Uint8List>();
    when(() => platform.readData(any(), any())).thenAnswer((_) => late.future);
    await expectLater(
      port.read(1, timeout: const Duration(milliseconds: 5)),
      throwsA(serialError(SerialErrorType.timeout)),
    );
    late.completeError(
      SerialError(type: SerialErrorType.ioError, message: 'gone'),
    );
    await expectLater(
      port.read(1),
      throwsA(serialError(SerialErrorType.ioError)),
    );
    when(() => platform.readData(any(), any()))
        .thenAnswer((_) async => Uint8List.fromList([3]));
    expect(await port.read(1), [3]);
  });

  test('closing drops a pending read: a reopened port reads afresh', () async {
    final stale = Completer<Uint8List>();
    when(() => platform.readData(any(), any())).thenAnswer((_) => stale.future);
    await expectLater(
      port.read(1, timeout: const Duration(milliseconds: 5)),
      throwsA(serialError(SerialErrorType.timeout)),
    );
    await port.close();
    await port.open(config);
    when(() => platform.readData(any(), any()))
        .thenAnswer((_) async => Uint8List.fromList([5]));
    expect(await port.read(1), [5]);
    stale.complete(Uint8List.fromList([0xEE])); // never delivered
  });

  test('reading a closed port fails', () async {
    await port.close();
    await expectLater(
      port.read(1),
      throwsA(serialError(SerialErrorType.portClosed)),
    );
  });

  group('other operations', () {
    test('defaults to the platform implementation', () {
      expect(DirectSerialPort().isOpen, isFalse);
    });

    test('config, streams and double open', () async {
      expect(port.isOpen, isTrue);
      expect(port.config, config);
      expect(port.dataStream, isA<Stream<Uint8List>>());
      expect(port.textStream, isA<Stream<String>>());
      expect(port.errorStream, isA<Stream<SerialError>>());
      await expectLater(
        port.open(config),
        throwsA(serialError(SerialErrorType.portAlreadyOpen)),
      );
      await port.close();
      expect(port.isOpen, isFalse);
      expect(
          () => port.config, throwsA(serialError(SerialErrorType.portClosed)));
    });

    test('readSync / readTextSync', () async {
      when(() => platform.readData(any(), any()))
          .thenAnswer((_) async => Uint8List.fromList('ok'.codeUnits));
      expect(await port.readSync(), 'ok'.codeUnits);
      expect(await port.readTextSync(), 'ok');
      verify(() => platform.readData(any(), 1024)).called(2);
    });

    test('readUntil finds the terminator, times out, or rethrows', () async {
      final chunks =
          ['a', 'b', '\n'].map((c) => Uint8List.fromList(c.codeUnits));
      final it = chunks.iterator;
      when(() => platform.readData(any(), any())).thenAnswer((_) async {
        return it.moveNext() ? it.current : Uint8List(0);
      });
      expect(await port.readUntil('\n'), 'ab\n');

      when(() => platform.readData(any(), any()))
          .thenAnswer((_) async => Uint8List(0));
      await expectLater(
        port.readUntil('\n', timeout: const Duration(milliseconds: 30)),
        throwsA(serialError(SerialErrorType.timeout)),
      );

      when(() => platform.readData(any(), any())).thenThrow(
        SerialError(type: SerialErrorType.ioError, message: 'x'),
      );
      await expectLater(
        port.readUntil('\n'),
        throwsA(serialError(SerialErrorType.ioError)),
      );
    });

    test('write, writeText and write timeout', () async {
      when(() => platform.writeData(any(), any())).thenAnswer(
          (i) async => (i.positionalArguments[1] as Uint8List).length);
      expect(await port.write(Uint8List.fromList([1, 2, 3])), 3);
      expect(await port.writeText('hi'), 2);

      when(() => platform.writeData(any(), any()))
          .thenAnswer((_) => Completer<int>().future);
      await expectLater(
        port.write(Uint8List(1), timeout: const Duration(milliseconds: 5)),
        throwsA(serialError(SerialErrorType.timeout)),
      );
    });

    test('flush, buffers, bytesAvailable and control lines', () async {
      when(() => platform.flush(any())).thenAnswer((_) async {});
      when(() => platform.resetBuffers(any())).thenAnswer((_) async {});
      when(() => platform.setDtr(any(), any())).thenAnswer((_) async {});
      when(() => platform.setRts(any(), any())).thenAnswer((_) async {});
      when(() => platform.getControlSignals(any()))
          .thenAnswer((_) async => const SerialControlSignals(cts: true));
      var n = 0;
      when(() => platform.bytesAvailable(any())).thenAnswer((_) async => n);

      await port.flush();
      await port.resetBuffers();
      await port.setDtr(true);
      await port.setRts(false);
      expect((await port.getControlSignals()).cts, isTrue);
      expect(await port.getCts(), isTrue);
      expect(await port.bytesAvailable(), 0);
      n = 4;
      expect(await port.bytesAvailable(), 4);
      verify(() => platform.setDtr('/dev/cu.test', true)).called(1);
      verify(() => platform.setRts('/dev/cu.test', false)).called(1);
    });

    test('every operation on a closed port fails with portClosed', () async {
      await port.close();
      final closed = throwsA(serialError(SerialErrorType.portClosed));
      await expectLater(port.close(), closed);
      await expectLater(port.readUntil('\n'), closed);
      await expectLater(port.write(Uint8List(1)), closed);
      await expectLater(port.flush(), closed);
      await expectLater(port.bytesAvailable(), closed);
      await expectLater(port.resetBuffers(), closed);
      await expectLater(port.getControlSignals(), closed);
      await expectLater(port.setDtr(true), closed);
      await expectLater(port.setRts(true), closed);
    });
  });
}
