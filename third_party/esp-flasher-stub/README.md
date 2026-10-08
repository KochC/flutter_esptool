# esp-flasher-stub (embedded binaries)

`lib/src/application/stub_loader_service.dart` embeds two flasher stubs that
are uploaded into the chip's RAM to erase and write flash. They are
Espressif's **esp-flasher-stub v0.7.0**, taken unmodified from esptool 4.12.0
(`esptool/targets/stub_flasher/2/`):

- Release and source: <https://github.com/espressif/esp-flasher-stub/releases/tag/v0.7.0>
- Copyright (c) 2025 Espressif Systems (Shanghai) CO LTD
- License: MIT OR Apache-2.0 (dual). This package uses it under the **MIT**
  license; both texts are kept here verbatim (`LICENSE-MIT`,
  `LICENSE-APACHE`). The MIT notice is also appended to the package
  `LICENSE`, so Flutter apps include it in their bundled `NOTICES`.

| Chip | Source file | text (B) | data (B) | entry | SHA-256 text | SHA-256 data |
|---|---|---|---|---|---|---|
| ESP32-S3 | `esp32s3.json` | 8480 | 252 | `0x4037800C` | `911d584127cbbecef6661d60aa0ff97357add29153fff10d98e700fb76f05b71` | `d02b76d857480cec0f861ef353009551feb7574deffca599cc1ea9d0758103f0` |
| ESP32-S2 | `esp32s2.json` | 7936 | 200 | `0x4002800C` | `f038186b9984b8767654ef1bd8da8d1b9db939762f2cb07a5854dcf0c1f8909f` | `a8897efc120fd1c7e74f439c3b8aea3488c84995c0ca2c514c2a5c25c78b6c9d` |

SHA-256 of the esptool JSON files: `esp32s3.json`
`9e2a0ec48b8150a1ff478eba9a44089c420a30810459ed5795dd139366ee6d22`,
`esp32s2.json`
`a4950d74e49c782a0920f1751c894dbb6b92624a213b7167fea1cedc7dc63714`.
`test/unit/application/stub_loader_service_test.dart` pins the binary hashes.

The optional NAND plugin in the S3 JSON is not embedded or uploaded.

Do **not** embed the stubs from esptool's `stub_flasher/1/` directory: those
are the legacy flasher stub, licensed GPL-2.0-or-later. Versions of this
package before this change embedded the legacy ESP32-S3 stub (from
esptool 4.8.1) and wrongly labelled it MIT.
