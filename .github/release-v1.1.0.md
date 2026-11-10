MZT Player 1.1.0 for Apple Silicon Macs running macOS 13 or later.

The tape encoder has been replaced with a specification-based implementation. The current source, build, tests and app bundle no longer require or include the earlier third-party converter or its source-level regression oracle.

- Generate PCM from a prepared signal plan using documented MZ-700 pulse widths.
- Synthesise at 48 kHz with cumulative transition timestamps, limiting quantisation error to half a sample without accumulating drift.
- Use LONG byte prefixes, most-significant-bit-first data, population-count checksums and conventional duplicate blocks.
- Retain single-copy mode with application-defined leaders of at least two seconds before the header and one second before the body.
- Share an immutable signal plan between independent tape and monitor cursors.
- Preserve playback controls, polarity reversal, device selection, independent output levels and the Sharp MZ ship icon.

Download **MZT-Player-1.1.0-macOS-arm64.zip**, extract it and move **MZT Player.app** to Applications. **SHA256SUMS.txt** contains the archive's checksum. This is an `arm64`-only, ad hoc signed build; it is not Apple-notarised or signed with a Developer ID certificate.

Validation: eight protocol-decoder tests and the AddressSanitizer/UndefinedBehaviorSanitizer harness passed. A fresh source export was used to check the build and tests without any earlier converter files. The release archive's contents, signature, architecture and macOS minimum were checked. Physical loading with the replacement timing implementation and live dual-device monitoring remain unverified.

This public repository starts at v1.1.0. The earlier converter and its releases are not included. Protocol references and implementation provenance are documented in the source.
