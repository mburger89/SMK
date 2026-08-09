// Board/connection-mode config, backed by Kconfig (main/Kconfig.projbuild).
// See Sources/smk/Bridging.h for the declarations Main.swift calls.
#include "sdkconfig.h"

int smk_has_wired_bridge(void) {
#if defined(CONFIG_SMK_HAS_WIRED_BRIDGE) && CONFIG_SMK_HAS_WIRED_BRIDGE
    return 1;
#else
    return 0;
#endif
}

int smk_default_mode_is_wired(void) {
#if defined(CONFIG_SMK_DEFAULT_MODE_WIRED) && CONFIG_SMK_DEFAULT_MODE_WIRED && \
    defined(CONFIG_SMK_HAS_WIRED_BRIDGE) && CONFIG_SMK_HAS_WIRED_BRIDGE
    return 1;
#else
    return 0;
#endif
}

int smk_has_rgb_backlight(void) {
#if defined(CONFIG_SMK_HAS_RGB_BACKLIGHT) && CONFIG_SMK_HAS_RGB_BACKLIGHT
    return 1;
#else
    return 0;
#endif
}

int smk_rgb_gpio(void) {
#if defined(CONFIG_SMK_RGB_GPIO)
    return CONFIG_SMK_RGB_GPIO;
#else
    return 16; // spare/unconnected pad on smk_kbd
#endif
}
