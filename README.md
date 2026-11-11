# MZT Player

Native macOS interface for playing Sharp MZT/MZF cassette images through a chosen Core Audio output. Built with SwiftUI, AVAudioEngine and a specification-based C encoder. Requires macOS 13 or later; no external libraries or tape-conversion programs are required.

## Run

For Apple Silicon Macs, download `MZT-Player-1.5.1-macOS-arm64.zip` from the repository's Releases page. Extract it and move **MZT Player.app** to Applications. The release includes `SHA256SUMS.txt` for checking the archive.

For a local build, run `./build.sh` and open `build/MZT Player.app`. `build/MZT Player.zip` is packaged before copying into a cloud-backed folder, avoiding Finder metadata that can interfere with signature verification.

1. Choose an `.mzt` or `.mzf` image.
2. Choose the output connected to the Sharp's cassette input.
3. Set the Sharp to load from tape, then press Play.
4. Adjust **Level** to suit the cassette interface. It starts at 50%.

The file panel lists every tape record in order, showing its embedded name, declared type and loading hint. All records are checked when an image opens. **Play Whole Tape** plays them in tape order. Uncheck any records you want to skip; if none are checked, playback is disabled. **Select whole tape** checks every record again. Machine-code records usually load from the ROM monitor. BASIC program records need a compatible interpreter first; data records and unknown types do not imply a direct loader. The type describes the header's declared format and does not establish compatibility with a particular Sharp model or BASIC version. Bytes outside printable ASCII in the tape name are shown in hexadecimal.

By default, **Between records** asks before the next record, with **Continue** and **Stop** in the dialogue. Choose **Wait 5 seconds** to continue automatically after a five-second gap. The wait applies between records actually being played, including checked selections. There is no wait before the first record or after the last.

Pause preserves encoder position. Stop rewinds. Pausing within a block can disrupt the Sharp's loader, so restart the load if necessary.

**Conventional** uses documented leaders and duplicate header/data blocks. **Short transfer** is the app default and uses single copies and approximately three seconds of leader before both the header and the data block. Both use the documented MZ-700 PWM timing profile. The polarity switch accommodates interfaces that invert the signal. Turbo loaders and speed corrections are not included.

## Quiet monitor

When the selected tape output differs from the macOS default output, a separate engine plays a quiet copy on the default device. The **Local monitor** slider adjusts its volume immediately, from -90 dB to -20 dB relative to the unattenuated signal. It starts at -70 dB. **Level** controls the tape output independently and starts at 50%.

The monitor's **Mute** control stops its engine without stopping the tape output. Unmuting starts a new monitor cursor at the current tape position. No monitor engine is opened if playback begins with the monitor muted. If both outputs refer to the same device, the monitor is skipped and both monitor controls are disabled. Controls update when the default or selected tape output changes.

Changing the macOS default output moves the monitor while leaving the selected tape output in place. Disconnecting the tape output stops playback. A configuration change affecting the tape engine also stops playback rather than moving the tape signal elsewhere.

The two devices have independent clocks and buffering. The monitor is an audible indication of progress, not a phase-synchronised second cassette output.

## Specification-based encoding

The encoder generates float mono PCM directly inside an `AVAudioSourceNode` callback at 48,000 samples/s. There is no temporary WAV or precomputed waveform. Rendering allocates no memory, takes no locks, performs no file I/O and calls no UI code. Core Audio converts the stream to the hardware sample rate.

The implementation uses the timing and framing documented for Sharp's MZ-700 cassette interface. It schedules physical transitions from cumulative microsecond timestamps, limiting timing quantisation to half a sample without accumulating per-pulse rounding error. Monitor cursors share an immutable signal plan with independent playback state.

See [the tape-format specification](docs/tape-format.md) for source references, pulse widths, byte framing, checksum rules, block structure, quantisation and the choices made for single-copy transfers.

Concatenated records are supported. Incomplete headers, truncated payloads and unexplained trailing bytes are rejected. An overall 1 MiB image limit bounds preparation memory; individual records support the full unsigned 16-bit payload-length range.

## Build and test

From this directory:

```sh
./build.sh
python3 Tests/test_encoder.py
./Tests/sanitise.sh
```

The build uses the installed Xcode toolchain and targets the host architecture. `TARGET_ARCH=arm64 ./build.sh` selects Apple Silicon explicitly. The app uses an ad hoc signature and is not Apple-notarised or signed with a Developer ID certificate.

Run `./release.sh` to create an Apple Silicon (`arm64`) ZIP and checksum under `build/release/`. The script checks that the executable contains only the `arm64` architecture.

The protocol tests decode physical PCM edges as a receiver would: classify symbols at the documented read point, parse byte prefixes, reconstruct data and check checksums. They also cover timing drift, arbitrary render-buffer boundaries, maximum payload sizes, checksum overflow, malformed images, concatenated records, EOF silence and independent monitor cursors. No third-party converter is compiled or executed. The C harness runs memory and boundary checks under AddressSanitizer and UndefinedBehaviorSanitizer.

A read-only diagnostic validates an image and lists audio outputs without opening a playback engine:

```sh
"build/MZT Player.app/Contents/MacOS/MZTPlayer" --check /path/to/image.mzt
```

Earlier GUI playback controls were checked on muted built-in speakers. Live dual-device monitoring and physical loading with the replacement timing implementation remain unverified. The USB audio interface is not used for automated playback tests.

## Notices and history

See [NOTICES.txt](NOTICES.txt) and [implementation provenance](docs/provenance.md). This repository starts from the v1.1.0 source snapshot and does not include the earlier converter, its Git history or its releases.

The icon is based on Sharp's historical MZ ship emblem. See [the icon notes](Assets/README.md). No project-wide licence is specified.
