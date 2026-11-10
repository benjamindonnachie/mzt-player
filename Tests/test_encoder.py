#!/usr/bin/env python3
"""Decode PCM and verify the documented Sharp MZ protocol, without a converter oracle."""
import ctypes
import itertools
import json
import pathlib
import struct
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SPEC = json.loads((ROOT/'Tests/fixtures/tape-protocol.json').read_text())
RATE = SPEC['sample_rate']


def image(body):
    header = bytearray(128)
    header[0] = 1
    struct.pack_into('<H', header, 18, len(body))
    return bytes(header) + body


def nearest_frame(us):
    return (us * RATE + 500000) // 1000000


class TapeDecoder:
    """A receiver: detect edges, classify at the 368 us read point, parse byte prefixes."""
    def __init__(self, test, pcm, inverted=False, origin_us=0):
        self.test = test
        # This test host uses IEEE-754 little-endian float32. Ignore magnitude
        # when detecting polarity, then check the measured high and low intervals.
        signs = pcm[3::4]
        runs = [(key, sum(1 for _ in group)) for key, group in itertools.groupby(signs)]
        test.assertEqual(len(runs) % 2, 0)
        self.bits = []
        self.duration_us = origin_us
        measured_frame = nearest_frame(origin_us)
        for n in range(0, len(runs), 2):
            high, low = runs[n], runs[n+1]
            test.assertEqual((high[0], low[0]), (0xbf, 0x3f) if inverted else (0x3f, 0xbf))
            # The documented receiver samples 368 us after the rising edge.
            bit = int(high[1] * 1000000 > 368 * RATE)
            self.bits.append(bit)
            kind = 'long' if bit else 'short'
            for measured, key in ((high[1], 'high'), (low[1], 'low')):
                nominal = SPEC[f'{kind}_{key}_us']
                test.assertLessEqual(abs(measured * 1000000 - nominal * RATE), 1000000)
                measured_frame += measured
                self.duration_us += nominal
                # Every edge stays within half a sample of its absolute timestamp.
                test.assertLessEqual(abs(measured_frame * 1000000 - self.duration_us * RATE), 500000)
        self.position = 0

    def pulses(self, bit, count):
        self.test.assertEqual(self.bits[self.position:self.position+count], [bit]*count)
        self.position += count

    def byte(self):
        self.pulses(1, 1)  # LONG precedes, rather than follows, every byte.
        bits = self.bits[self.position:self.position+8]
        self.test.assertEqual(len(bits), 8)
        self.position += 8
        return sum(bit << (7-index) for index, bit in enumerate(bits))

    def block(self, expected):
        decoded = bytes(self.byte() for _ in range(len(expected)))
        self.test.assertEqual(decoded, expected)
        checksum = self.byte()*256 + self.byte()
        self.test.assertEqual(checksum, sum(byte.bit_count() for byte in decoded) % 65536)
        self.pulses(1, 1)  # One terminal LONG after the checksum.
        return checksum

    def record(self, data, duplicated):
        body_size = struct.unpack_from('<H', data, 18)[0]
        header, body = data[:128], data[128:128+body_size]
        for payload, mark, leader in (
            (header, 40, 22000 if duplicated else 3969),
            (body, 20, 11000 if duplicated else 1985),
        ):
            self.pulses(0, leader)
            self.pulses(1, mark)
            self.pulses(0, mark)
            self.pulses(1, 1)
            self.block(payload)
            if duplicated:
                self.pulses(0, 256)
                self.block(payload)


class EncoderTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        library = pathlib.Path(cls.temp.name)/'tape.dylib'
        subprocess.run(['xcrun', 'clang', '-std=c11', '-Wall', '-Wextra', '-Werror',
                        '-dynamiclib', '-O2', str(ROOT/'Sources/Encoder/Encoder.c'),
                        '-o', str(library)], check=True)
        cls.lib = ctypes.CDLL(str(library))
        cls.lib.mzt_create.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_int,
                                       ctypes.c_int, ctypes.c_void_p, ctypes.c_size_t]
        cls.lib.mzt_create.restype = ctypes.c_void_p
        cls.lib.mzt_copy_at_frame.argtypes = [ctypes.c_void_p, ctypes.c_uint64]
        cls.lib.mzt_copy_at_frame.restype = ctypes.c_void_p
        cls.lib.mzt_destroy.argtypes = [ctypes.c_void_p]
        cls.lib.mzt_render.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_size_t]
        cls.lib.mzt_sample_rate.restype = ctypes.c_uint32
        for name in ('mzt_total_frames', 'mzt_played_frames'):
            function = getattr(cls.lib, name)
            function.argtypes = [ctypes.c_void_p]
            function.restype = ctypes.c_uint64

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def create(self, data, duplicated=True, inverted=False):
        error = ctypes.create_string_buffer(256)
        tape = self.lib.mzt_create(data, len(data), duplicated, inverted, error, len(error))
        self.assertTrue(tape, error.value.decode())
        return tape

    def read(self, tape, count, chunk=4093):
        result = bytearray()
        buffer = (ctypes.c_float * chunk)()
        while count:
            n = min(count, chunk)
            self.lib.mzt_render(tape, buffer, n)
            result.extend(bytes(buffer)[:n*4])
            count -= n
        return bytes(result)

    def verify(self, records, duplicated, inverted):
        tape = self.create(b''.join(records), duplicated, inverted)
        try:
            self.assertEqual(self.lib.mzt_sample_rate(), RATE)
            frames = self.lib.mzt_total_frames(tape)
            pcm = self.read(tape, frames)
            levels = set(struct.unpack("<1024f", pcm[:4096]))
            self.assertEqual(levels, {-0.625, 0.625})
            decoder = TapeDecoder(self, pcm, inverted)
            for record in records:
                decoder.record(record, duplicated)
            self.assertEqual(decoder.position, len(decoder.bits))
            self.assertEqual(frames, nearest_frame(decoder.duration_us))
            self.assertEqual(self.lib.mzt_played_frames(tape), frames)
            self.assertEqual(self.read(tape, 257), bytes(257*4))
            self.assertEqual(self.lib.mzt_played_frames(tape), frames)
        finally:
            self.lib.mzt_destroy(tape)

    def test_documented_byte_and_checksum_vector(self):
        body = bytes.fromhex(SPEC['payload_hex'])
        self.assertEqual([format(byte, '08b') for byte in body], SPEC['payload_bits'])
        data = image(body)
        self.assertEqual(sum(byte.bit_count() for byte in body), int(SPEC['payload_checksum_hex'], 16))
        self.assertEqual(sum(byte.bit_count() for byte in data[:128]), int(SPEC['header_checksum_hex'], 16))
        for duplicated in (False, True):
            for inverted in (False, True):
                with self.subTest(duplicated=duplicated, inverted=inverted):
                    self.verify([data], duplicated, inverted)

    def test_all_byte_values(self):
        self.verify([image(bytes(range(256)))], True, False)

    def test_multiple_records_and_empty_body(self):
        self.verify([image(b''), image(b'abc'), image(b'\xff')], True, True)

    def test_rounding_does_not_accumulate_drift(self):
        tape = self.create(image(b'1234'))
        try:
            # A complete 22,000-pulse header leader occupies exactly 11.088 s.
            leader = nearest_frame(22000 * (240+264))
            self.assertEqual(leader, 532224)
            pcm = self.read(tape, leader)
            decoder = TapeDecoder(self, pcm)
            self.assertEqual(decoder.bits, [0]*22000)
            # Pulses cannot all have the same integer number of samples.
            widths = [sum(1 for _ in group) for _, group in itertools.groupby(pcm[3::4])]
            self.assertGreater(len(set(widths)), 1)
        finally:
            self.lib.mzt_destroy(tape)

    def test_maximum_payload_and_checksum_wrap(self):
        for count in (65407, 65408, 65535):
            with self.subTest(count=count):
                data = image(b'\xff'*count)
                tape = self.create(data, False)
                try:
                    checksum = (8*count) % 65536
                    # Seek to the body's two checksum bytes and terminal pulse.
                    ones = checksum.bit_count()
                    tail_us = (2+ones+1)*958 + (16-ones)*504
                    total = self.lib.mzt_total_frames(tape)
                    # Determine the exact checksum boundary from protocol counts,
                    # including the fractional sample remainder from earlier data.
                    h_ones = sum(b.bit_count() for b in data[:128])
                    header_sum = h_ones % 65536
                    h_bits_ones = h_ones + header_sum.bit_count()
                    h_us = (130+h_bits_ones+1)*958 + (8*130-h_bits_ones)*504
                    before_us = (3969+1985)*504 + (40+20)*(958+504) + 2*958 + h_us + count*9*958
                    self.assertEqual(total, nearest_frame(before_us+tail_us))
                    copy = self.lib.mzt_copy_at_frame(tape, nearest_frame(before_us))
                    try:
                        tail = self.read(copy, total-nearest_frame(before_us))
                        decoder = TapeDecoder(self, tail, origin_us=before_us)
                        self.assertEqual(decoder.byte()*256+decoder.byte(), checksum)
                        decoder.pulses(1, 1)
                        self.assertEqual(decoder.position, len(decoder.bits))
                    finally:
                        self.lib.mzt_destroy(copy)
                finally:
                    self.lib.mzt_destroy(tape)

    def test_chunk_size_does_not_change_samples(self):
        data = image(b'\xa5\x00\xff')
        first = self.create(data, False)
        second = self.create(data, False)
        try:
            count = self.lib.mzt_total_frames(first)
            self.assertEqual(self.read(first, count, count), self.read(second, count, 17))
        finally:
            self.lib.mzt_destroy(first); self.lib.mzt_destroy(second)

    def test_monitor_seek_and_shared_plan_lifetime(self):
        data = image(b'1234') + image(bytes(range(256)))
        source = self.create(data, False)
        total = self.lib.mzt_total_frames(source)
        baseline = self.read(source, total)
        try:
            for frame in (0, 1, 11, 12, 23, 24, 96020, total//2, total-1, total, total+99):
                copy = self.lib.mzt_copy_at_frame(source, frame)
                self.assertTrue(copy)
                try:
                    start = min(frame, total)
                    expected = baseline[start*4:(start+2048)*4].ljust(2048*4, b'\0')
                    self.assertEqual(self.read(copy, 2048), expected)
                finally:
                    self.lib.mzt_destroy(copy)
            survivor = self.lib.mzt_copy_at_frame(source, 37)
        finally:
            self.lib.mzt_destroy(source)
        try:
            self.assertEqual(self.read(survivor, 257), baseline[37*4:(37+257)*4])
        finally:
            self.lib.mzt_destroy(survivor)

    def test_rejects_incomplete_or_oversized_images(self):
        for data in (b'', b'\x01', bytes(127), image(b'1234')[:-1], image(b'')+b'x', bytes(1024*1024+1)):
            with self.subTest(length=len(data)):
                error = ctypes.create_string_buffer(256)
                tape = self.lib.mzt_create(data, len(data), 1, 0, error, len(error))
                self.assertFalse(tape)
                self.assertTrue(error.value)


if __name__ == '__main__':
    unittest.main(verbosity=2)
