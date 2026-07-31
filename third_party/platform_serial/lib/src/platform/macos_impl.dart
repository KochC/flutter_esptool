// coverage:ignore-file

import 'dart:async';
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../models/serial_error.dart';

/// macOS FFI implementation for enumerating and using serial ports.
class MacOSSerialImpl {
  static _MacOSSerialBindings? _cachedBindings;
  static final Map<String, _MacOSPortState> _ports = {};

  static _MacOSSerialBindings get _bindings {
    if (!Platform.isMacOS) {
      throw UnsupportedError('MacOSSerialImpl is available on macOS only.');
    }
    return _cachedBindings ??= _MacOSSerialBindings.open();
  }

  /// Gets the available serial ports through IOKit.
  static Future<List<Map<String, dynamic>>> getAvailablePorts() async {
    final jsonPointerPointer = calloc<ffi.Pointer<Utf8>>();
    try {
      final status = _bindings.getAvailablePortsJson(jsonPointerPointer);
      if (status < 0) {
        throw _lastError('Error retrieving macOS ports');
      }

      final jsonPointer = jsonPointerPointer.value;
      if (jsonPointer == ffi.nullptr) {
        return const [];
      }

      final payload = jsonPointer.toDartString();
      final decoded = jsonDecode(payload);
      if (decoded is! List) {
        return const [];
      }

      return decoded
          .whereType<Map<dynamic, dynamic>>()
          .map((port) => Map<String, dynamic>.from(port))
          .toList(growable: false);
    } on FormatException catch (error, stackTrace) {
      throw SerialError(
        type: SerialErrorType.ioError,
        message: 'Invalid macOS JSON payload: $error',
        stackTrace: stackTrace,
      );
    } finally {
      final jsonPointer = jsonPointerPointer.value;
      if (jsonPointer != ffi.nullptr) {
        _bindings.freeMemory(jsonPointer.cast());
      }
      calloc.free(jsonPointerPointer);
    }
  }

  /// Opens and configures a native serial port.
  static Future<void> openPort({
    required String portName,
    required int baudRate,
    required int dataBits,
    required int stopBits,
    required int parity,
    required int flowControl,
    required int readTimeout,
    required int writeTimeout,
  }) async {
    if (_ports.containsKey(portName)) {
      throw SerialError(
        type: SerialErrorType.portAlreadyOpen,
        message: 'Port $portName is already open on macOS',
      );
    }

    final portNamePointer = portName.toNativeUtf8();
    try {
      final handle = _bindings.openPort(
        portNamePointer,
        baudRate,
        dataBits,
        stopBits,
        parity,
        flowControl,
        readTimeout,
        writeTimeout,
      );
      if (handle == 0) {
        throw _lastError('Error opening port on macOS');
      }

      _ports[portName] = _MacOSPortState(
        portName: portName,
        handle: handle,
        readTimeoutMs: readTimeout,
        writeTimeoutMs: writeTimeout,
      );
    } finally {
      calloc.free(portNamePointer);
    }
  }

  /// Closes an open port and releases the associated native resources.
  static Future<void> closePort(String portName) async {
    final state = _ports.remove(portName);
    if (state == null) {
      throw SerialError(
        type: SerialErrorType.portClosed,
        message: 'Port $portName is not open on macOS',
      );
    }

    await state.dispose();

    final status = _bindings.closePort(state.handle);
    if (status < 0) {
      throw _lastError('Error closing port on macOS');
    }
  }

  /// Reads up to [length] bytes from the port.
  ///
  /// [timeoutMs] overrides the port's configured read timeout for this call.
  /// If omitted, the port's configured [_MacOSPortState.readTimeoutMs] is used.
  ///
  /// Instead of passing the full timeout to the blocking C `read()` call
  /// (which would stall the Dart isolate for the entire duration), this method
  /// polls `bytesAvailable()` in a Dart async loop and only calls the native
  /// `read()` when data is actually present — using timeout=0 so the C call
  /// returns immediately.  Between polls it yields via [Future.delayed] so
  /// the Flutter UI isolate stays fully responsive.
  static Future<Uint8List> readData(
    String portName,
    int length, {
    int? timeoutMs,
  }) async {
    final state = _requirePort(portName);
    if (length <= 0) return Uint8List(0);

    final handle = state.handle;
    final deadlineMs = DateTime.now().millisecondsSinceEpoch +
        (timeoutMs ?? state.readTimeoutMs);

    while (true) {
      // Check how many bytes are available without blocking.
      final available = _bindings.bytesAvailable(handle);
      if (available < 0) {
        throw _lastError('Error reading on macOS');
      }

      if (available > 0) {
        // Data is ready — read immediately with timeout=0 (non-blocking).
        final readLength = available < length ? available : length;
        final buffer = calloc<ffi.Uint8>(readLength);
        try {
          final bytesRead = _bindings.read(handle, buffer, readLength, 0);
          if (bytesRead < 0) throw _lastError('Error reading on macOS');
          if (bytesRead == 0) return Uint8List(0);
          return Uint8List.fromList(buffer.asTypedList(bytesRead));
        } finally {
          calloc.free(buffer);
        }
      }

      // No data yet — check deadline before yielding.
      if (DateTime.now().millisecondsSinceEpoch >= deadlineMs) {
        return Uint8List(0); // timeout — caller treats empty as a timeout
      }

      // Yield to the event loop for one frame (~1 ms) before polling again.
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
  }

  /// Writes [data] to the port without blocking the Dart isolate.
  ///
  /// Instead of passing the full write timeout to the blocking C `write()`
  /// call, this method calls `write()` with `timeout=0` (non-blocking) in an
  /// async loop, yielding via [Future.delayed] between attempts so the Flutter
  /// UI isolate stays responsive.  On a serial port the kernel output buffer
  /// is essentially always writable for small packets so the first call
  /// typically writes all bytes immediately.
  static Future<int> writeData(
    String portName,
    Uint8List data, {
    int? timeoutMs,
  }) async {
    if (data.isEmpty) return 0;
    final state = _requirePort(portName);
    final handle = state.handle;
    final effectiveTimeoutMs = timeoutMs ?? state.writeTimeoutMs;
    final deadlineMs =
        DateTime.now().millisecondsSinceEpoch + effectiveTimeoutMs;

    final pointer = calloc<ffi.Uint8>(data.length);
    try {
      pointer.asTypedList(data.length).setAll(0, data);
      var totalWritten = 0;

      while (totalWritten < data.length) {
        // Non-blocking write attempt (timeout=0): returns immediately if the
        // kernel output buffer is not ready, or writes as many bytes as fit.
        final bytesWritten = _bindings.write(
          handle,
          ffi.Pointer<ffi.Uint8>.fromAddress(
            pointer.address + totalWritten,
          ),
          data.length - totalWritten,
          0, // timeout=0 → non-blocking
        );

        if (bytesWritten < 0) {
          throw _lastError('Error writing on macOS');
        }
        totalWritten += bytesWritten;

        if (totalWritten >= data.length) break;

        // Output buffer not ready yet — check deadline then yield.
        if (DateTime.now().millisecondsSinceEpoch >= deadlineMs) {
          throw _lastError('Write timeout on macOS');
        }
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }

      return totalWritten;
    } finally {
      calloc.free(pointer);
    }
  }

  /// Returns the number of bytes available in the kernel input buffer.
  static Future<int> bytesAvailable(String portName) async {
    final state = _requirePort(portName);
    final available = _bindings.bytesAvailable(state.handle);
    if (available < 0) {
      throw _lastError('Error retrieving available bytes on macOS');
    }
    return available;
  }

  /// Resets the input and output buffers of the port.
  static Future<void> resetBuffers(String portName) async {
    final state = _requirePort(portName);
    final status = _bindings.resetBuffers(state.handle);
    if (status < 0) {
      throw _lastError('Error resetting buffers on macOS');
    }
  }

  /// Waits for the output buffer to drain.
  static Future<void> flush(String portName) async {
    final state = _requirePort(portName);
    final status = _bindings.flush(state.handle);
    if (status < 0) {
      throw _lastError('Error flushing buffer on macOS');
    }
  }

  /// Produces a broadcast stream of data or error events for the port.
  static Stream<dynamic> getEventStream(String portName) {
    final state = _requirePort(portName);
    return state.ensureStream(
      bindings: _bindings,
      readData: (length) => readData(portName, length),
      buildError: (message) =>
          SerialError(type: SerialErrorType.ioError, message: message),
    );
  }

  static _MacOSPortState _requirePort(String portName) {
    final state = _ports[portName];
    if (state == null) {
      throw SerialError(
        type: SerialErrorType.portClosed,
        message: 'Port $portName is not open on macOS',
      );
    }
    return state;
  }

  static SerialError _lastError(String fallbackMessage) {
    final errorCode = _bindings.getLastErrorCode();
    final messagePointer = _bindings.copyLastErrorMessage();
    String? nativeMessage;

    if (messagePointer != ffi.nullptr) {
      nativeMessage = messagePointer.toDartString();
      _bindings.freeMemory(messagePointer.cast());
    }

    return SerialError(
      type: _mapErrorCode(errorCode),
      message: nativeMessage == null || nativeMessage.isEmpty
          ? fallbackMessage
          : '$fallbackMessage: $nativeMessage',
    );
  }

  static SerialErrorType _mapErrorCode(int errorCode) {
    switch (errorCode) {
      case 2:
        return SerialErrorType.portNotFound;
      case 13:
      case 1:
        return SerialErrorType.permissionDenied;
      case 16:
      case 37:
        return SerialErrorType.portAlreadyOpen;
      case 22:
      case 45:
        return SerialErrorType.configurationError;
      case 60:
        return SerialErrorType.timeout;
      case 55:
      case 84:
        return SerialErrorType.bufferOverflow;
      default:
        return SerialErrorType.ioError;
    }
  }
}

typedef _GetAvailablePortsJsonNative = ffi.Int32 Function(
    ffi.Pointer<ffi.Pointer<Utf8>>);
typedef _OpenPortNative = ffi.IntPtr Function(
  ffi.Pointer<Utf8>,
  ffi.Int32,
  ffi.Int32,
  ffi.Int32,
  ffi.Int32,
  ffi.Int32,
  ffi.Int32,
  ffi.Int32,
);
typedef _ClosePortNative = ffi.Int32 Function(ffi.IntPtr);
typedef _ReadNative = ffi.Int32 Function(
  ffi.IntPtr,
  ffi.Pointer<ffi.Uint8>,
  ffi.Int32,
  ffi.Int32,
);
typedef _WriteNative = ffi.Int32 Function(
  ffi.IntPtr,
  ffi.Pointer<ffi.Uint8>,
  ffi.Int32,
  ffi.Int32,
);
typedef _HandleOnlyNative = ffi.Int32 Function(ffi.IntPtr);
typedef _WaitReadableNative = ffi.Int32 Function(ffi.IntPtr, ffi.Int32);
typedef _GetLastErrorCodeNative = ffi.Int32 Function();
typedef _CopyLastErrorMessageNative = ffi.Pointer<Utf8> Function();
typedef _FreeMemoryNative = ffi.Void Function(ffi.Pointer<ffi.Void>);

/// Lazy wrapper for the native functions exposed by the macOS pod.
class _MacOSSerialBindings {
  _MacOSSerialBindings._(ffi.DynamicLibrary library)
      : getAvailablePortsJson = library.lookupFunction<
                _GetAvailablePortsJsonNative,
                int Function(ffi.Pointer<ffi.Pointer<Utf8>>)>(
            'serial_get_available_ports_json'),
        openPort = library.lookupFunction<
            _OpenPortNative,
            int Function(ffi.Pointer<Utf8>, int, int, int, int, int, int,
                int)>('serial_open_port'),
        closePort = library.lookupFunction<_ClosePortNative, int Function(int)>(
          'serial_close_port',
        ),
        read = library.lookupFunction<_ReadNative,
            int Function(int, ffi.Pointer<ffi.Uint8>, int, int)>('serial_read'),
        write = library.lookupFunction<
            _WriteNative,
            int Function(
                int, ffi.Pointer<ffi.Uint8>, int, int)>('serial_write'),
        bytesAvailable =
            library.lookupFunction<_HandleOnlyNative, int Function(int)>(
          'serial_bytes_available',
        ),
        waitReadable =
            library.lookupFunction<_WaitReadableNative, int Function(int, int)>(
          'serial_wait_readable',
        ),
        flush = library.lookupFunction<_HandleOnlyNative, int Function(int)>(
          'serial_flush',
        ),
        resetBuffers =
            library.lookupFunction<_HandleOnlyNative, int Function(int)>(
          'serial_reset_buffers',
        ),
        getLastErrorCode =
            library.lookupFunction<_GetLastErrorCodeNative, int Function()>(
          'serial_get_last_error_code',
        ),
        copyLastErrorMessage = library.lookupFunction<
            _CopyLastErrorMessageNative,
            ffi.Pointer<Utf8> Function()>('serial_copy_last_error_message'),
        freeMemory = library.lookupFunction<_FreeMemoryNative,
            void Function(ffi.Pointer<ffi.Void>)>('serial_free_memory');

  final int Function(ffi.Pointer<ffi.Pointer<Utf8>>) getAvailablePortsJson;
  final int Function(ffi.Pointer<Utf8>, int, int, int, int, int, int, int)
      openPort;
  final int Function(int) closePort;
  final int Function(int, ffi.Pointer<ffi.Uint8>, int, int) read;
  final int Function(int, ffi.Pointer<ffi.Uint8>, int, int) write;
  final int Function(int) bytesAvailable;
  final int Function(int, int) waitReadable;
  final int Function(int) flush;
  final int Function(int) resetBuffers;
  final int Function() getLastErrorCode;
  final ffi.Pointer<Utf8> Function() copyLastErrorMessage;
  final void Function(ffi.Pointer<ffi.Void>) freeMemory;

  static _MacOSSerialBindings open() =>
      _MacOSSerialBindings._(ffi.DynamicLibrary.process());
}

class _MacOSPortState {
  _MacOSPortState({
    required this.portName,
    required this.handle,
    required this.readTimeoutMs,
    required this.writeTimeoutMs,
  });

  final String portName;
  final int handle;
  final int readTimeoutMs;
  final int writeTimeoutMs;

  final StreamController<dynamic> _controller =
      StreamController<dynamic>.broadcast();
  Timer? _timer;
  bool _polling = false;

  Stream<dynamic> ensureStream({
    required _MacOSSerialBindings bindings,
    required Future<Uint8List> Function(int length) readData,
    required SerialError Function(String message) buildError,
  }) {
    _timer ??= Timer.periodic(const Duration(milliseconds: 40), (_) async {
      if (!_controller.hasListener) {
        _timer?.cancel();
        _timer = null;
        return;
      }
      if (_polling) {
        return;
      }

      _polling = true;
      try {
        final waitResult = bindings.waitReadable(handle, 0);
        if (waitResult < 0) {
          if (!_controller.isClosed) {
            _controller.add({
              'type': 'error',
              'message': 'Error monitoring serial port $portName',
            });
          }
          return;
        }
        if (waitResult == 0) {
          return;
        }

        final available = bindings.bytesAvailable(handle);
        if (available < 0) {
          if (!_controller.isClosed) {
            _controller.add({
              'type': 'error',
              'message': 'Error retrieving available bytes for $portName',
            });
          }
          return;
        }

        final payload = await readData(available > 0 ? available : 1);
        if (payload.isNotEmpty && !_controller.isClosed) {
          _controller.add({
            'type': 'data',
            'data': payload.toList(growable: false),
          });
        }
      } on SerialError catch (error) {
        if (!_controller.isClosed) {
          _controller.add({'type': 'error', 'message': error.message});
        }
      } catch (error) {
        if (!_controller.isClosed) {
          _controller.add({
            'type': 'error',
            'message': buildError('macOS stream error: $error').message,
          });
        }
      } finally {
        _polling = false;
      }
    });

    return _controller.stream;
  }

  Future<void> dispose() async {
    _timer?.cancel();
    _timer = null;
    if (!_controller.isClosed) {
      await _controller.close();
    }
  }
}
