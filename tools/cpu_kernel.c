#include <stdint.h>

/* Compile separately, without LTO, so repeated identical inputs still execute. */
void tile_multiply(const int8_t *a, const int8_t *b, int32_t *out) {
    for (int r = 0; r < 4; ++r)
        for (int c = 0; c < 4; ++c) {
            int32_t sum = 0;
            for (int k = 0; k < 4; ++k)
                sum += (int32_t)a[r*4+k] * (int32_t)b[k*4+c];
            out[r*4+c] = sum;
        }
}
