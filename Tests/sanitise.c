#include "Encoder.h"
#include <assert.h>
#include <stdlib.h>
#include <string.h>

int main(void) {
    char error[512];
    unsigned char *image = calloc(65535+128, 1);
    assert(image);
    for (size_t n = 0; n < 128; n++) {
        MZTTape *bad = mzt_create(image, n, 1, 0, error, sizeof(error));
        assert(!bad);
    }
    image[18] = image[19] = 255;
    for (size_t n = 128; n < 65535+128; n += 127) {
        MZTTape *bad = mzt_create(image, n, 1, 0, error, sizeof(error));
        assert(!bad);
    }
    memset(image+128, 0xa5, 65535);
    MZTTape *t = mzt_create(image, 65535+128, 1, 1, error, sizeof(error));
    assert(t);
    float output[257];
    while (mzt_played_frames(t) < mzt_total_frames(t)) mzt_render(t, output, 257);
    mzt_render(t, output, 257);
    for (int i = 0; i < 257; i++) assert(output[i] == 0);
    MZTTape *copy = mzt_copy_at_frame(t, 400000);
    assert(copy);
    mzt_render(copy, output, 257);
    mzt_destroy(copy); mzt_destroy(t); free(image);
    return 0;
}
