#define _POSIX_C_SOURCE 200809L
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <errno.h>

void tile_multiply(const int8_t *, const int8_t *, int32_t *);
static uint64_t now_ns(void) {
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts)) { perror("clock_gettime"); exit(1); }
    return (uint64_t)ts.tv_sec * 1000000000ULL + (uint64_t)ts.tv_nsec;
}
static unsigned count(const char *s, unsigned max, int zero_ok) {
    char *end;
    errno = 0;
    unsigned long n = strtoul(s, &end, 10);
    if (errno || *end || end == s || n > max || (!zero_ok && n == 0)) {
        fprintf(stderr, "Invalid count: %s\n", s); exit(1);
    }
    return (unsigned)n;
}
int main(int argc, char **argv) {
    if (argc != 4) { fprintf(stderr, "usage: cpu_benchmark repetitions samples warmup < 32-byte-input\n"); return 1; }
    unsigned repetitions = count(argv[1], 1000000, 0);
    unsigned samples = count(argv[2], 1000000, 0);
    unsigned warmup = count(argv[3], 1000000, 1);
    int8_t a[16], b[16];
    int32_t out[16];
    if (fread(a, 1, 16, stdin) != 16 || fread(b, 1, 16, stdin) != 16) {
        fprintf(stderr, "Expected two 4x4 int8 matrices\n"); return 1;
    }
    uint64_t checksum = 0;
    for (unsigned w = 0; w < warmup; ++w)
        for (unsigned i = 0; i < repetitions; ++i) tile_multiply(a, b, out);
    printf("{\"compiler\":\"%s\",\"ns_per_tile\":[", __VERSION__);
    for (unsigned s = 0; s < samples; ++s) {
        uint64_t start = now_ns();
        for (unsigned i = 0; i < repetitions; ++i) tile_multiply(a, b, out);
        uint64_t elapsed = now_ns() - start;
        checksum += (uint32_t)out[s % 16];
        printf("%s%.6f", s ? "," : "", (double)elapsed / repetitions);
    }
    printf("],\"checksum\":%llu,\"result\":[", (unsigned long long)checksum);
    for (int i = 0; i < 16; ++i) printf("%s%d", i ? "," : "", (int)out[i]);
    puts("]}");
    return 0;
}
