#ifndef MZT_ENCODER_H
#define MZT_ENCODER_H
#include <stddef.h>
#include <stdint.h>
typedef struct MZTTape MZTTape;
// Creation validates the image and prepares an immutable signal plan.
// Render has one audio-thread owner per cursor and performs no allocation or I/O.
// Monitor copies share the read-only plan and have independent cursor state.
MZTTape *mzt_create(const unsigned char *data, size_t length, int conventional,
                    int inverted, char *error, size_t error_size);
MZTTape *mzt_copy_at_frame(const MZTTape *source, uint64_t frame);
void mzt_destroy(MZTTape *tape);
void mzt_render(MZTTape *tape, float *output, size_t frames);
uint32_t mzt_sample_rate(void);
uint64_t mzt_total_frames(const MZTTape *tape);
uint64_t mzt_played_frames(const MZTTape *tape);
#endif
