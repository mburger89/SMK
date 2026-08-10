// Wrapper functions for pico-sdk GPIO static-inline functions.
// These wrappers allow Embedded Swift to call static inline pico-sdk functions
// via @_extern(c, ...) declarations. The pico-sdk's gpio.h functions are
// static inline, meaning they're not exported symbols when the header is only
// included in Swift code (which doesn't inline C). These wrappers provide
// non-inline entry points for the same functionality.

#include "hardware/gpio.h"

// Wrapper for gpio_init (already extern, not static inline)
// — included for completeness/clarity

// Wrappers for static inline functions
void smk_gpio_set_dir(uint gpio, bool out) {
    gpio_set_dir(gpio, out);
}

void smk_gpio_pull_up(uint gpio) {
    gpio_pull_up(gpio);
}

void smk_gpio_pull_down(uint gpio) {
    gpio_pull_down(gpio);
}

void smk_gpio_put(uint gpio, bool value) {
    gpio_put(gpio, value);
}
