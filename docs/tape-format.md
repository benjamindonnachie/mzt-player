# Sharp MZ cassette protocol

This document records the factual protocol inputs for the specification-based encoder in `Sources/Encoder/Encoder.c`. No tape-conversion program is used as a source of timing constants, implementation code or expected output in the current build or tests.

## References

1. **Sharp Corporation, MZ-700 Service Manual**, code 00ZMZ700SM/E, printed page 13 (PDF page 14), section 4, cassette controller. [Service manual scan](https://www.sharpmz.no/original/mz-700/download/1u06_sm.pdf); [alternative manual viewer](https://www.manualslib.com/manual/583936/Sharp-Mz-700.html?page=14#manual). The diagram was checked visually against the service-manual scan available in the surrounding research workspace. The manual itself is not bundled with the app or repository.
2. **Karl-Heinz Mau, Tape data processing**, updated 15 May 2004. [Technical investigation](https://www.idealine.info/sharpmz/mz-700/tapeproc.htm). This describes the cassette protocol and identifies relevant monitor entry points.
3. **MZ-700 1Z-013A monitor listing**, published through the same technical archive. [Listing archive](https://www.idealine.info/sharpmz/download/mz700lst.zip). Read only to check the on-tape framing and checksum interpretation: `WBYTE` at 0x0767, `WTAPE` at 0x048A, `CKSUM` at 0x071A and `GAP` at 0x077A. No listing or ROM code is copied into this repository or translated into the implementation.

## Physical timing

The MZ-700 service-manual diagram specifies these logical intervals:

| Symbol | HIGH | LOW | Complete pulse |
| --- | ---: | ---: | ---: |
| Zero / SHORT | 240 microseconds | 264 microseconds | 504 microseconds |
| One / LONG | 464 microseconds | 494 microseconds | 958 microseconds |

The documented read point is 368 microseconds after a rising edge. HIGH begins each logical pulse. Interface circuitry can invert physical polarity, so the app retains a polarity switch.

This is explicitly the **MZ-700 timing profile**. It is not a claim that every Sharp MZ model has identical timing. MZ-1500 hardware compatibility still requires a physical loading test.

## Framing

The header is 128 bytes; its payload-size field occupies offsets 0x12 and 0x13, low byte first. Each byte on tape has a LONG prefix followed by eight data bits, most significant first. The checksum is the population count of the block's data bits modulo 65,536, transmitted high byte first with the same byte framing. A single LONG terminates each completed block copy.

Conventional recording uses a 22,000-SHORT header leader and an 11,000-SHORT body leader. The header marker is 40 LONG, 40 SHORT, one LONG; the body marker is 20 LONG, 20 SHORT, one LONG. The first byte's prefix is separate from the marker. Each block is written twice with 256 SHORT pulses between copies. The second copy repeats the data and checksum.

The manual's “10 sec” and “5 sec” leader annotations are nominal descriptions. This implementation follows the explicit pulse counts and widths. For example, 22,000 SHORT pulses take 11.088 seconds at the listed 504-microsecond width.

## Application choices

These are implementation decisions, not additional requirements claimed for the Sharp format:

- PCM runs at 48,000 samples per second. Each transition is positioned by rounding its accumulated microsecond timestamp to the nearest sample. Rounding restarts only at the beginning of a whole tape image, including concatenated records. Error at any transition is at most half a sample (about 10.42 microseconds); per-pulse rounding does not accumulate drift.
- Logical HIGH and LOW use +0.625 and -0.625 float PCM before the independently controlled output gains. These levels provide headroom and are not electrical voltage specifications.
- Single-copy mode omits duplicates and uses 5,953 SHORT pulses (3.000312 seconds) before both header and body markers. In the MZ-700 monitor listing, both read paths call MOTOR (0x069F) before searching for the marker, allowing roughly two seconds for the motor to settle. The longer leaders allow for that delay and leave time to detect the leader. This choice is not yet verified on physical MZ-1500 hardware. In conventional mode, RTAPE (0x050E) returns after a successful checksum and searches for the duplicate only on failure; the machine can therefore finish before the sender has played the entire waveform.
- Concatenated MZT/MZF records are played without an invented inter-record silence. The next record has its own leader.
- A zero-length payload is accepted and represented by an empty body block with a zero checksum. This is an application edge-case policy; it does not claim that the monitor's normal save command produces empty body blocks.
- An overall 1 MiB input limit bounds preparation memory. Input parsing requires complete headers and the complete payload declared by each header; unexplained trailing bytes are rejected.
- Audio remains silent after the final LOW interval. No amplitude fades are added to the signal.

## Implementation and verification

Preparation creates an immutable plan of repeated-symbol and framed-byte operations, with exact durations in microseconds. A playback cursor generates transitions from that plan. Monitor cursors share its read-only data and retain independent timing state; seeking skips whole operations before finding the target edge. Rendering allocates no memory, performs no I/O and takes no locks.

`Tests/fixtures/tape-protocol.json` contains the documented timing values and a small hand-checkable byte/checksum vector. The Python tests inspect physical PCM edges, classify bits at the receiver read point, parse prefixed bytes and check the decoded blocks and checksums. They also check absolute timing error, sample-buffer boundaries, maximum payload lengths, checksum overflow, end-of-stream silence, monitor seeking and plan lifetime. They do not compile or execute a third-party converter.
