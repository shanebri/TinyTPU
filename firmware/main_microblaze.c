/* Bare-metal, polled AXI UARTLite transport for TinyTPU.
 * Add this as src/main.c in an empty Vitis application, alongside the
 * tiny_tpu_server.c handler and its header. No text uses the binary UART.
 */
#include <stdint.h>
#include "xparameters.h"
#include "xil_io.h"
#include "xuartlite_l.h"
#include "sleep.h"
#include "tiny_tpu_server.h"

#define UART_BASE ((UINTPTR)XPAR_AXI_UARTLITE_0_BASEADDR)
#define TPU_BASE  ((UINTPTR)XPAR_TOP_0_BASEADDR)
#define IDLE_POLL_US 100U
#define PACKET_IDLE_POLLS 1000U /* At least about 100 ms, plus poll overhead. */
#define TPU_STATUS_POLL_LIMIT 10000000U

/* Inspect these with the debugger; never print them on the protocol UART. */
volatile uint32_t tpu_packets_handled;
volatile uint32_t tpu_uart_errors;
volatile uint32_t tpu_packet_timeouts;
volatile uint32_t tpu_last_status;

static uint32_t read_tpu(void *context, uint32_t offset)
{
    return Xil_In32(*(UINTPTR *)context + offset);
}

static void write_tpu(void *context, uint32_t offset, uint32_t value)
{
    Xil_Out32(*(UINTPTR *)context + offset, value);
}

int main(void)
{
    UINTPTR tpu_base = TPU_BASE;
    uint8_t request[TPU_REQUEST_BYTES];
    uint8_t response[TPU_RESPONSE_BYTES];
    unsigned received = 0;
    unsigned idle_polls = 0;

    /* Reset both FIFOs, leaving interrupts disabled for this polling server. */
    XUartLite_WriteReg(UART_BASE, XUL_CONTROL_REG_OFFSET,
                      XUL_CR_FIFO_RX_RESET | XUL_CR_FIFO_TX_RESET);
    write_tpu(&tpu_base, 0x00, 2); /* Clear stale accelerator state. */

    for (;;) {
        uint32_t flags = XUartLite_ReadReg(UART_BASE, XUL_STATUS_REG_OFFSET);
        if (flags & (XUL_SR_FRAMING_ERROR | XUL_SR_PARITY_ERROR |
                     XUL_SR_OVERRUN_ERROR)) {
            ++tpu_uart_errors;
            received = 0;
            idle_polls = 0;
            XUartLite_WriteReg(UART_BASE, XUL_CONTROL_REG_OFFSET,
                              XUL_CR_FIFO_RX_RESET);
            continue;
        }

        if (!(flags & XUL_SR_RX_FIFO_VALID_DATA)) {
            if (received != 0) {
                usleep(IDLE_POLL_US);
                if (++idle_polls >= PACKET_IDLE_POLLS) {
                    ++tpu_packet_timeouts;
                    received = 0;
                    idle_polls = 0;
                }
            }
            continue;
        }

        uint8_t byte = (uint8_t)XUartLite_ReadReg(UART_BASE, XUL_RX_FIFO_OFFSET);
        idle_polls = 0;
        if (received == 0) {
            if (byte == 'T') request[received++] = byte;
        } else if (received == 1) {
            if (byte == 'P') request[received++] = byte;
            else if (byte != 'T') received = 0;
            /* Another T remains a potential start: T T P is recognized. */
        } else {
            /* TP inside a fixed-length body is payload, not a new header. */
            request[received++] = byte;
        }

        if (received == TPU_REQUEST_BYTES) {
            tpu_last_status = (uint32_t)tpu_handle_request(
                request, response, read_tpu, write_tpu, &tpu_base,
                TPU_STATUS_POLL_LIMIT);
            for (unsigned i = 0; i < TPU_RESPONSE_BYTES; ++i)
                XUartLite_SendByte(UART_BASE, response[i]);
            ++tpu_packets_handled;
            received = 0;
        }
    }
}
