import 'dart:async';
import 'dart:typed_data';

import 'contracts/serial_port_interface.dart';
import 'models/serial_config.dart';
import 'models/serial_control_signals.dart';
import 'models/serial_error.dart';
import 'platform/serial_platform_interface.dart';

/// A [SerialPortInterface] that routes directly to the platform implementation
/// without starting any background polling stream.
///
/// [SerialPort] starts a 40 ms periodic timer ([_MacOSPortState.ensureStream])
/// the moment the port is opened and listens on the event stream.  That timer
/// races against explicit [read] calls and consumes bytes before they can be
/// returned to the caller — which breaks the SLIP framing loop in
/// [EspTransport].
///
/// [DirectSerialPort] skips the event-stream subscription entirely: every
/// [read] / [bytesAvailable] / [write] call goes straight to the platform
/// layer with no concurrent timer stealing bytes.
class DirectSerialPort implements SerialPortInterface {
  DirectSerialPort({SerialPlatformInterface? platform})
      : _platform = platform ?? SerialPlatformInterface();

  final SerialPlatformInterface _platform;

  SerialConfig? _config;
  bool _isOpen = false;

  /// A platform read that outlived its caller's [read] timeout.
  ///
  /// [Future.timeout] only stops *waiting*: the platform read keeps polling
  /// (on macOS until the port's own read deadline) and consumes whatever
  /// arrives next. Starting a second platform read beside it would race it —
  /// the orphan wins and its bytes are dropped (observed: the ESP stub's
  /// ERASE_FLASH reply lost after a 0.5 s OHAI poll timed out, then a
  /// 300 s "Timed out waiting for an ESP response"). The next [read] awaits
  /// this read instead, so its bytes reach the caller.
  Future<Uint8List>? _pendingRead;

  // Unused stream stubs required by the interface.
  final _dataStream = StreamController<Uint8List>.broadcast();
  final _textStream = StreamController<String>.broadcast();
  final _errorStream = StreamController<SerialError>.broadcast();

  @override
  SerialConfig get config =>
      _config ??
      (throw SerialError(
        type: SerialErrorType.portClosed,
        message: 'Port not configured',
      ));

  @override
  bool get isOpen => _isOpen;

  @override
  Stream<Uint8List> get dataStream => _dataStream.stream;

  @override
  Stream<String> get textStream => _textStream.stream;

  @override
  Stream<SerialError> get errorStream => _errorStream.stream;

  @override
  Future<void> open(SerialConfig config) async {
    if (_isOpen) {
      throw SerialError(
        type: SerialErrorType.portAlreadyOpen,
        message: 'Port ${config.portName} is already open',
      );
    }
    await _platform.openPort(config);
    _config = config;
    _isOpen = true;
    // Intentionally no event-stream subscription — see class doc.
  }

  @override
  Future<void> close() async {
    if (!_isOpen || _config == null) {
      throw SerialError(
        type: SerialErrorType.portClosed,
        message: 'Port not open',
      );
    }
    final portName = _config!.portName;
    _isOpen = false;
    _config = null;
    _pendingRead = null; // belongs to this session; never hand it to the next
    await (_platform as dynamic).closePort(portName) as dynamic;
  }

  @override
  Future<Uint8List> read(int length, {Duration? timeout}) async {
    if (!_isOpen || _config == null) {
      throw SerialError(
        type: SerialErrorType.portClosed,
        message: 'Port not open',
      );
    }
    final t = timeout ?? _config!.readTimeout;
    // ignore: avoid_print
    print(
        '${DateTime.now().toIso8601String()} [DSP] read(length=$length timeout=${t.inMilliseconds}ms)');
    // Resume a read that timed out earlier rather than racing it (see
    // [_pendingRead]); only start a new platform read when none is running.
    final resumed = _pendingRead != null;
    final pending =
        _pendingRead ?? _platform.readData(_config!.portName, length);
    _pendingRead = pending;
    try {
      final result = await pending.timeout(t);
      if (identical(_pendingRead, pending)) _pendingRead = null;
      // ignore: avoid_print
      print(
          '${DateTime.now().toIso8601String()} [DSP] read returned ${result.length} bytes${resumed ? ' (resumed)' : ''}');
      return result;
    } on TimeoutException {
      // Keep [_pendingRead]: its bytes belong to the next read.
      // ignore: avoid_print
      print(
          '${DateTime.now().toIso8601String()} [DSP] read TimeoutException after ${t.inMilliseconds}ms');
      throw SerialError(
        type: SerialErrorType.timeout,
        message: 'Read timeout',
      );
    } catch (e) {
      if (identical(_pendingRead, pending)) _pendingRead = null;
      // ignore: avoid_print
      print('${DateTime.now().toIso8601String()} [DSP] read threw: $e');
      rethrow;
    }
  }

  @override
  Future<Uint8List> readSync({Duration? timeout}) =>
      read(1024, timeout: timeout);

  @override
  Future<String> readTextSync({Duration? timeout}) async {
    final data = await readSync(timeout: timeout);
    return String.fromCharCodes(data);
  }

  @override
  Future<String> readUntil(String terminator, {Duration? timeout}) async {
    if (!_isOpen || _config == null) {
      throw SerialError(
        type: SerialErrorType.portClosed,
        message: 'Port not open',
      );
    }
    final buffer = StringBuffer();
    final t = timeout ?? _config!.readTimeout;
    final deadline = DateTime.now().add(t);

    while (DateTime.now().isBefore(deadline)) {
      try {
        final data = await _platform.readData(_config!.portName, 1);
        if (data.isNotEmpty) {
          buffer.write(String.fromCharCodes(data));
          if (buffer.toString().endsWith(terminator)) {
            return buffer.toString();
          }
        }
      } catch (_) {
        rethrow;
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    throw SerialError(
      type: SerialErrorType.timeout,
      message: 'Timeout searching for terminator',
    );
  }

  @override
  Future<int> write(Uint8List data, {Duration? timeout}) async {
    if (!_isOpen || _config == null) {
      throw SerialError(
        type: SerialErrorType.portClosed,
        message: 'Port not open',
      );
    }
    final t = timeout ?? _config!.writeTimeout;
    try {
      return await _platform.writeData(_config!.portName, data).timeout(t);
    } on TimeoutException {
      throw SerialError(
        type: SerialErrorType.timeout,
        message: 'Write timeout',
      );
    }
  }

  @override
  Future<int> writeText(String data, {Duration? timeout}) =>
      write(Uint8List.fromList(data.codeUnits), timeout: timeout);

  @override
  Future<void> flush() async {
    if (!_isOpen || _config == null) {
      throw SerialError(
        type: SerialErrorType.portClosed,
        message: 'Port not open',
      );
    }
    await _platform.flush(_config!.portName);
  }

  @override
  Future<int> bytesAvailable() async {
    if (!_isOpen || _config == null) {
      throw SerialError(
        type: SerialErrorType.portClosed,
        message: 'Port not open',
      );
    }
    final n = await _platform.bytesAvailable(_config!.portName);
    // Only log when bytes are actually available (suppress zero-spam).
    if (n > 0) {
      // ignore: avoid_print
      print('${DateTime.now().toIso8601String()} [DSP] bytesAvailable=$n');
    }
    return n;
  }

  @override
  Future<void> resetBuffers() async {
    if (!_isOpen || _config == null) {
      throw SerialError(
        type: SerialErrorType.portClosed,
        message: 'Port not open',
      );
    }
    await _platform.resetBuffers(_config!.portName);
  }

  @override
  Future<SerialControlSignals> getControlSignals() async {
    if (!_isOpen || _config == null) {
      throw SerialError(
        type: SerialErrorType.portClosed,
        message: 'Port not open',
      );
    }
    return _platform.getControlSignals(_config!.portName);
  }

  @override
  Future<bool> getCts() async {
    final signals = await getControlSignals();
    return signals.cts;
  }

  @override
  Future<void> setDtr(bool enabled) async {
    if (!_isOpen || _config == null) {
      throw SerialError(
        type: SerialErrorType.portClosed,
        message: 'Port not open',
      );
    }
    await _platform.setDtr(_config!.portName, enabled);
  }

  @override
  Future<void> setRts(bool enabled) async {
    if (!_isOpen || _config == null) {
      throw SerialError(
        type: SerialErrorType.portClosed,
        message: 'Port not open',
      );
    }
    await _platform.setRts(_config!.portName, enabled);
  }
}
