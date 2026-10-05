#include "tiny_tpu_server.h"
#include <string.h>

static uint16_t crc16(const uint8_t *p, unsigned length) {
    uint16_t crc = 0xffff;
    for (unsigned i = 0; i < length; ++i) {
        crc ^= (uint16_t)p[i] << 8;
        for (unsigned bit = 0; bit < 8; ++bit)
            crc = (uint16_t)((crc << 1) ^ ((crc & 0x8000) ? 0x1021 : 0));
    }
    return crc;
}
static uint32_t load32(const uint8_t *p) {
    return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
}
static void store32(uint8_t *p, uint32_t value) {
    for (unsigned j = 0; j < 4; ++j) p[j] = (uint8_t)(value >> (8*j));
}
int tpu_handle_request(const uint8_t request[TPU_REQUEST_BYTES],
                       uint8_t response[TPU_RESPONSE_BYTES],
                       tpu_read32 read32, tpu_write32 write32,
                       void *context, uint32_t poll_limit) {
    uint32_t repetitions = load32(request+4);
    unsigned status = 0;
    memset(response, 0, TPU_RESPONSE_BYTES);
    response[0] = 'T'; response[1] = 'R'; response[2] = 1;
    response[4] = 4; response[5] = 4; response[6] = 4;
    response[7] = 8; response[8] = 32;
    store32(response+10, read32(context, 0x0c));
    store32(response+14, repetitions);
    uint16_t received_crc = (uint16_t)(request[40] | (uint16_t)request[41] << 8);
    if (crc16(request+2, 38) != received_crc) status = 1;
    else if (request[0] != 'T' || request[1] != 'P' || request[2] != 1 || request[3] != 1 ||
             repetitions == 0 || repetitions > 1000000) status = 2;
    else if (read32(context, 0x20) != 0x20080404 || read32(context, 0x24) != 0x00010004 ||
             repetitions > read32(context, 0x28)) status = 5;
    else if (read32(context, 0x04) & 1) status = 4;
    else {
        write32(context, 0x00, 2); // clear stale done/error and result
        for (unsigned j = 0; j < 4; ++j) {
            write32(context, 0x40 + 4*j, load32(request+8 + 4*j));
            write32(context, 0x50 + 4*j, load32(request+24 + 4*j));
        }
        write32(context, 0x08, repetitions);
        write32(context, 0x00, 1);
        unsigned complete = 0;
        for (uint32_t poll = 0; poll < poll_limit; ++poll) {
            uint32_t flags = read32(context, 0x04);
            if (flags & 4) { status = 6; break; }
            if ((flags & 3) == 2) { complete = 1; break; }
        }
        if (complete) {
            if (read32(context, 0x1c) != repetitions) status = 6;
            else {
                store32(response+18, read32(context, 0x10));
                store32(response+22, read32(context, 0x14));
                store32(response+26, read32(context, 0x18));
                for (unsigned j = 0; j < 16; ++j)
                    store32(response+30+4*j, read32(context, 0x80+4*j));
            }
        } else {
            if (!status) status = 3;
            write32(context, 0x00, 2); // abort on timeout/hardware error
        }
    }
    response[3] = (uint8_t)status;
    uint16_t crc = crc16(response+2, 92);
    response[94] = (uint8_t)crc;
    response[95] = (uint8_t)(crc >> 8);
    return (int)status;
}
