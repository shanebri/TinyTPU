package tpu_pkg;
    // Default array dimensions; both must be at least one.
    parameter int unsigned ARRAY_ROWS = 4;
    parameter int unsigned ARRAY_COLS = 4;

    // Activations and weights are signed two's-complement integers.
    parameter int unsigned DATA_WIDTH = 8;
    // Use at least 2 * DATA_WIDTH bits to retain a full product.
    // Extra bits allow longer accumulation; overflow wraps (no saturation).
    parameter int unsigned ACC_WIDTH = 32;
endpackage : tpu_pkg
