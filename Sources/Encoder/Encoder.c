/* Specification-based Sharp MZ PWM synthesiser.
 * Protocol references and application choices: docs/tape-format.md.
 * A bounded immutable signal plan is prepared before playback. The audio
 * callback consumes it without allocation, I/O, locks or floating-point timing.
 */
#include "Encoder.h"
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define SAMPLE_RATE 48000u
#define HEADER_BYTES 128u
#define IMAGE_LIMIT (1024u * 1024u)
#define PCM_PEAK 0.625f

typedef enum { SHORT_PULSE, LONG_PULSE } Pulse;
typedef enum { REPEAT_PULSE, SERIAL_BYTES } Operation;
typedef struct {
    Operation operation;
    Pulse pulse;
    size_t offset, count;
    uint16_t checksum;
    uint64_t duration_us;
} Instruction;
typedef struct {
    atomic_uint references;
    unsigned char *image;
    Instruction *instructions;
    size_t instruction_count;
    uint64_t duration_us;
    uint64_t frames;
    int inverted;
} SignalPlan;
struct MZTTape {
    SignalPlan *plan;
    size_t instruction, symbol;
    uint64_t boundary_us, edge_frame, frame;
    unsigned pending_low_us;
    float level;
    atomic_uint_fast64_t reported_frame;
};

static const unsigned high_us[] = { 240, 464 };
static const unsigned low_us[] = { 264, 494 };
static uint64_t pulse_us(Pulse pulse) { return high_us[pulse] + low_us[pulse]; }
static uint64_t sample_boundary(uint64_t microseconds) {
    return (microseconds * SAMPLE_RATE + 500000u) / 1000000u;
}
static unsigned bit_count(unsigned char byte) {
    // Population count of an eight-bit value, independent of host intrinsics.
    byte = byte - ((byte >> 1) & 0x55);
    byte = (byte & 0x33) + ((byte >> 2) & 0x33);
    return (byte + (byte >> 4)) & 0x0f;
}
static void append_tone(SignalPlan *plan, Pulse pulse, size_t repetitions) {
    Instruction *item = &plan->instructions[plan->instruction_count++];
    *item = (Instruction){ .operation = REPEAT_PULSE, .pulse = pulse,
        .count = repetitions, .duration_us = repetitions * pulse_us(pulse) };
    plan->duration_us += item->duration_us;
}
static void append_bytes(SignalPlan *plan, size_t offset, size_t count) {
    uint32_t population = 0;
    for (size_t n = 0; n < count; n++) population += bit_count(plan->image[offset+n]);
    uint16_t checksum = (uint16_t)population;
    uint64_t ones = population + bit_count(checksum >> 8) + bit_count(checksum & 255);
    uint64_t framed_bytes = count + 2; // payload followed by big-endian checksum
    uint64_t long_count = framed_bytes + ones + 1; // byte prefixes and final terminator
    uint64_t short_count = 8 * framed_bytes - ones;
    Instruction *item = &plan->instructions[plan->instruction_count++];
    *item = (Instruction){ .operation = SERIAL_BYTES, .offset = offset, .count = count,
        .checksum = checksum, .duration_us = short_count * pulse_us(SHORT_PULSE)
                                               + long_count * pulse_us(LONG_PULSE) };
    plan->duration_us += item->duration_us;
}
static void append_block(SignalPlan *plan, size_t offset, size_t count,
                         unsigned marker, unsigned leader, int duplicated) {
    append_tone(plan, SHORT_PULSE, leader);
    append_tone(plan, LONG_PULSE, marker);
    append_tone(plan, SHORT_PULSE, marker);
    append_tone(plan, LONG_PULSE, 1);
    append_bytes(plan, offset, count);
    if (duplicated) {
        append_tone(plan, SHORT_PULSE, 256);
        append_bytes(plan, offset, count);
    }
}
static MZTTape *new_cursor(SignalPlan *plan) {
    MZTTape *cursor = calloc(1, sizeof(*cursor));
    if (cursor) { cursor->plan = plan; atomic_init(&cursor->reported_frame, 0); }
    return cursor;
}
MZTTape *mzt_create(const unsigned char *data, size_t length, int conventional,
                    int inverted, char *error, size_t error_size) {
    const char *problem = NULL;
    size_t records = 0;
    if (!data || length < HEADER_BYTES) problem = "An MZT image needs a complete 128-byte header.";
    else if (length > IMAGE_LIMIT) problem = "The tape image exceeds the 1 MiB limit.";
    else {
        size_t offset = 0;
        while (offset < length) {
            if (length - offset < HEADER_BYTES) {
                problem = "The last MZT header is incomplete."; break;
            }
            size_t payload = data[offset+18] + 256u * data[offset+19];
            if (payload > length - offset - HEADER_BYTES) {
                problem = "The payload is shorter than the size in its MZT header."; break;
            }
            offset += HEADER_BYTES + payload;
            records++;
        }
    }
    if (problem) { if (error && error_size) snprintf(error, error_size, "%s", problem); return NULL; }
    SignalPlan *plan = calloc(1, sizeof(*plan));
    MZTTape *cursor = NULL;
    if (plan) {
        atomic_init(&plan->references, 1);
        plan->image = malloc(length);
        // At most seven instructions per block, two blocks per record.
        plan->instructions = calloc(records * 14, sizeof(Instruction));
        cursor = new_cursor(plan);
    }
    if (!plan || !plan->image || !plan->instructions || !cursor) {
        if (plan) { free(plan->image); free(plan->instructions); free(plan); }
        free(cursor);
        if (error && error_size) snprintf(error, error_size, "Insufficient memory to prepare the tape.");
        return NULL;
    }
    memcpy(plan->image, data, length);
    plan->inverted = inverted != 0;
    for (size_t offset = 0; offset < length;) {
        size_t payload = data[offset+18] + 256u * data[offset+19];
        // Single-copy leaders are application choices: at least two seconds
        // before the header and one second before the body, rounded up in pulses.
        append_block(plan, offset, HEADER_BYTES, 40, conventional ? 22000 : 3969, conventional);
        append_block(plan, offset+HEADER_BYTES, payload, 20, conventional ? 11000 : 1985, conventional);
        offset += HEADER_BYTES + payload;
    }
    plan->frames = sample_boundary(plan->duration_us);
    return cursor;
}
void mzt_destroy(MZTTape *cursor) {
    if (!cursor) return;
    SignalPlan *plan = cursor->plan;
    if (atomic_fetch_sub_explicit(&plan->references, 1, memory_order_acq_rel) == 1) {
        free(plan->image); free(plan->instructions); free(plan);
    }
    free(cursor);
}
// Read a protocol symbol from the immutable instruction plan.
static int next_pulse(MZTTape *cursor, Pulse *result) {
    SignalPlan *plan = cursor->plan;
    while (cursor->instruction < plan->instruction_count) {
        const Instruction *item = &plan->instructions[cursor->instruction];
        size_t limit = item->operation == REPEAT_PULSE ? item->count : (item->count+2)*9+1;
        if (cursor->symbol == limit) {
            cursor->instruction++; cursor->symbol = 0; continue;
        }
        size_t symbol = cursor->symbol++;
        if (item->operation == REPEAT_PULSE) { *result = item->pulse; return 1; }
        if (symbol == limit-1 || symbol % 9 == 0) { *result = LONG_PULSE; return 1; }
        size_t byte_index = symbol / 9;
        unsigned char byte;
        if (byte_index < item->count) byte = plan->image[item->offset + byte_index];
        else if (byte_index == item->count) byte = item->checksum >> 8;
        else byte = item->checksum & 255;
        unsigned bit = 8 - symbol % 9;
        *result = byte & (1u << bit) ? LONG_PULSE : SHORT_PULSE;
        return 1;
    }
    return 0;
}
// Advance one physical transition using cumulative microsecond timestamps.
static int next_edge(MZTTape *cursor) {
    unsigned duration;
    if (cursor->pending_low_us) {
        duration = cursor->pending_low_us;
        cursor->pending_low_us = 0;
        cursor->level = -PCM_PEAK;
    } else {
        Pulse pulse;
        if (!next_pulse(cursor, &pulse)) return 0;
        duration = high_us[pulse];
        cursor->pending_low_us = low_us[pulse];
        cursor->level = PCM_PEAK;
    }
    if (cursor->plan->inverted) cursor->level = -cursor->level;
    cursor->boundary_us += duration;
    cursor->edge_frame = sample_boundary(cursor->boundary_us);
    return 1;
}
MZTTape *mzt_copy_at_frame(const MZTTape *source, uint64_t frame) {
    SignalPlan *plan = source->plan;
    MZTTape *copy = new_cursor(plan);
    if (!copy) return NULL;
    atomic_fetch_add_explicit(&plan->references, 1, memory_order_relaxed);
    if (frame > plan->frames) frame = plan->frames;
    // Skip complete instructions, then resolve only the target instruction's edges.
    while (copy->instruction < plan->instruction_count) {
        uint64_t next_us = copy->boundary_us + plan->instructions[copy->instruction].duration_us;
        if (sample_boundary(next_us) > frame) break;
        copy->boundary_us = next_us;
        copy->instruction++;
    }
    copy->edge_frame = sample_boundary(copy->boundary_us);
    while (copy->edge_frame <= frame && next_edge(copy)) {}
    copy->frame = frame;
    atomic_store_explicit(&copy->reported_frame, frame, memory_order_release);
    return copy;
}
void mzt_render(MZTTape *cursor, float *output, size_t frames) {
    size_t filled = 0;
    while (filled < frames) {
        if (cursor->frame == cursor->edge_frame && !next_edge(cursor)) break;
        uint64_t available = cursor->edge_frame - cursor->frame;
        size_t count = frames - filled;
        if (available < count) count = (size_t)available;
        for (size_t i = 0; i < count; i++) output[filled+i] = cursor->level;
        filled += count;
        cursor->frame += count;
    }
    if (filled < frames) memset(output+filled, 0, (frames-filled)*sizeof(float));
    atomic_store_explicit(&cursor->reported_frame, cursor->frame, memory_order_release);
}
uint32_t mzt_sample_rate(void) { return SAMPLE_RATE; }
uint64_t mzt_total_frames(const MZTTape *cursor) { return cursor->plan->frames; }
uint64_t mzt_played_frames(const MZTTape *cursor) {
    return atomic_load_explicit(&cursor->reported_frame, memory_order_acquire);
}
