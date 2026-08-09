// Task 1 stub — minimal C entry point calling into the Swift smoke test.
// Replaced with the real platform_glue.c (kb_log, vTaskDelay, etc.) in
// Task 3, matching ports/rp2040/platform/platform_glue.c's role.
#include <errno.h>
#include <malloc.h>
#include <stddef.h>

extern void app_main_swift(void);

int main(void) {
    app_main_swift();
    return 0;
}

// --- posix_memalign (not in newlib; needed by Swift's swift_allocObject) ----
// Swift's Embedded runtime allocates heap objects with posix_memalign for
// alignment guarantees; newlib doesn't provide it. Even this trivial smoke
// test pulls it in transitively via the Embedded Swift runtime, so it's
// needed to link, same as ports/rp2040/platform/platform_glue.c.
int posix_memalign(void **memptr, size_t alignment, size_t size) {
    if (alignment == 0 || (alignment & (alignment - 1)) != 0) return EINVAL;
    if (size == 0) { *memptr = NULL; return 0; }
    void *p = memalign(alignment, size);
    if (p == NULL) return ENOMEM;
    *memptr = p;
    return 0;
}
