#ifndef TINY_TPU_SERVER_H
#define TINY_TPU_SERVER_H
#include <stdint.h>

#define TPU_REQUEST_BYTES 42
#define TPU_RESPONSE_BYTES 96

/* Offsets are relative to the peripheral base, not absolute AXI addresses. */
typedef uint32_t (*tpu_read32)(void *context, uint32_t offset);
typedef void (*tpu_write32)(void *context, uint32_t offset, uint32_t value);

/* Handle one COMPLETE packet. Your UART server owns framing and I/O.
 * poll_limit bounds status-register reads; use a value appropriate to your CPU.
 * No UART driver, BSP, heap, or printf dependency. Returns response status.
 */
int tpu_handle_request(const uint8_t request[TPU_REQUEST_BYTES],
                       uint8_t response[TPU_RESPONSE_BYTES],
                       tpu_read32 read32, tpu_write32 write32,
                       void *context, uint32_t poll_limit);
#endif
