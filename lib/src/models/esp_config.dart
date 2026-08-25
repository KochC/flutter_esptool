// Copyright (c) 2026 Piergiorgio Vagnozzi
// Licensed under the MIT License.

/// How the transport should reset the chip into ROM bootloader mode.
enum EspResetMode {
  /// Classic DTR/RTS reset (external USB-UART adapters: CP210x, CH340, FTDI).
  classic,

  /// USB JTAG/Serial reset sequence for chips with built-in USB (ESP32-S2/S3,
  /// C3, C6, H2).  DTR/RTS lines are toggled in a specific pattern that the
  /// USB Serial/JTAG peripheral interprets as a bootloader-entry request.
  usbJtag,

  /// ESP32-S2 native USB-OTG (CDC/ACM) reset. The S2 has NO USB-Serial/JTAG
  /// peripheral: it uses the **classic** DTR/RTS pin sequence to drive EN/IO0,
  /// BUT — like the JTAG chips — the device re-enumerates when it reboots into
  /// the ROM USB-CDC bootloader, so the port must be closed, given time to
  /// re-enumerate, then reopened (unlike a plain UART-bridge classic reset,
  /// where the same USB device persists).
  usbOtg,

  /// Skip the hardware reset entirely — assume the chip is already in ROM
  /// bootloader mode.  Use this for ESP32-S3 USB JTAG devices that are
  /// already awaiting SYNC (e.g. freshly powered or manually held in boot).
  none,
}

/// Configuration for an ESP serial session.
class EspConfig {
  /// Creates an [EspConfig].
  const EspConfig({
    required this.portName,
    this.initialBaudRate = 115200,
    this.flashBaudRate = 460800,
    this.timeout = const Duration(seconds: 3),
    this.syncRetries = 10,
    this.flashBlockSize = 0x4000,
    this.resetMode = EspResetMode.classic,
  });

  /// The serial port name.
  final String portName;

  /// The baud rate used for the initial ROM connection.
  final int initialBaudRate;

  /// The baud rate used for higher speed flashing.
  final int flashBaudRate;

  /// The default command timeout.
  final Duration timeout;

  /// The number of sync retries.
  final int syncRetries;

  /// The flash block size.
  final int flashBlockSize;

  /// The reset strategy to use when entering ROM bootloader mode.
  final EspResetMode resetMode;

  /// Creates a copy of this config with modified values.
  EspConfig copyWith({
    String? portName,
    int? initialBaudRate,
    int? flashBaudRate,
    Duration? timeout,
    int? syncRetries,
    int? flashBlockSize,
    EspResetMode? resetMode,
  }) {
    return EspConfig(
      portName: portName ?? this.portName,
      initialBaudRate: initialBaudRate ?? this.initialBaudRate,
      flashBaudRate: flashBaudRate ?? this.flashBaudRate,
      timeout: timeout ?? this.timeout,
      syncRetries: syncRetries ?? this.syncRetries,
      flashBlockSize: flashBlockSize ?? this.flashBlockSize,
      resetMode: resetMode ?? this.resetMode,
    );
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is EspConfig &&
            portName == other.portName &&
            initialBaudRate == other.initialBaudRate &&
            flashBaudRate == other.flashBaudRate &&
            timeout == other.timeout &&
            syncRetries == other.syncRetries &&
            flashBlockSize == other.flashBlockSize &&
            resetMode == other.resetMode;
  }

  @override
  int get hashCode => Object.hash(
        portName,
        initialBaudRate,
        flashBaudRate,
        timeout,
        syncRetries,
        flashBlockSize,
        resetMode,
      );

  @override
  String toString() {
    return 'EspConfig(portName: $portName, initialBaudRate: $initialBaudRate, '
        'flashBaudRate: $flashBaudRate, timeout: $timeout, '
        'syncRetries: $syncRetries, flashBlockSize: $flashBlockSize, '
        'resetMode: $resetMode)';
  }
}
