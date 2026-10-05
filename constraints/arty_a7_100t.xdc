# TinyTPU MicroBlaze system: Digilent Arty A7-100 Rev. D / Rev. E.
# Apply to the generated block-design HDL wrapper, not arty_top.sv.
# Pin source:
# https://github.com/Digilent/digilent-xdc/blob/master/Arty-A7-100-Master.xdc
# Expected wrapper ports: sys_clock, reset, usb_uart_rxd, usb_uart_txd.
# Rename get_ports targets if your generated wrapper uses different names.
# Avoid duplicate pin/clock definitions in other project constraint files.

# Onboard 100 MHz oscillator -> Clocking Wizard input.
set_property -dict {PACKAGE_PIN E3 IOSTANDARD LVCMOS33} [get_ports {sys_clock}]
create_clock -name sys_clock_100mhz -period 10.000 -waveform {0.000 5.000} [get_ports {sys_clock}]

# Dedicated active-low board reset (CK_RST), not one of btn[0..3].
# Configure Processor System Reset ext_reset_in as active-low.
# Existing reset inverter supplies an active-high Clocking Wizard reset.
set_property -dict {PACKAGE_PIN C2 IOSTANDARD LVCMOS33} [get_ports {reset}]

# USB-UART bridge TX -> FPGA RX -> AXI UARTLite rx input.
set_property -dict {PACKAGE_PIN A9 IOSTANDARD LVCMOS33} [get_ports {usb_uart_rxd}]

# AXI UARTLite tx output -> FPGA TX -> USB-UART bridge RX.
set_property -dict {PACKAGE_PIN D10 IOSTANDARD LVCMOS33} [get_ports {usb_uart_txd}]

# Clocking Wizard supplies its own generated-clock constraints.
# AXI, MicroBlaze, local BRAM, and TPU signals are internal, with no board pins.
# No broad timing exceptions or DRC severity overrides are applied here.
