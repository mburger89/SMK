// Task 1 stub — minimal C entry point calling into the Swift smoke test.
// Replaced with the real platform_glue.c (kb_log, vTaskDelay, etc.) in
// Task 4, matching ports/nrf52840/platform/platform_glue.c's role.
//
// posix_memalign/_init are needed even for this minimal smoke test, not
// just the full app: Swift's Embedded runtime (swift_allocObject/
// swift_slowAlloc) unconditionally references posix_memalign, and
// startup_stm32f411xe.s's Reset_Handler unconditionally calls
// __libc_init_array (which calls _init) before main() — found empirically
// via real link errors during this port's Task 1, not anticipated by the
// plan. _init would normally come from crti.o/crtn.o, but CMakeLists.txt's
// -nostartfiles excludes those, so a trivial no-op stub is needed here
// instead. The rest of newlib's syscall stubs (_exit/_sbrk/_write/_read/
// etc., also referenced transitively once any libc object pulls another
// in) are satisfied by CMakeLists.txt's --specs=nosys.specs link flag,
// which provide their own always-fails stub bodies — cheaper than hand
// -writing 7 more stub functions here for functionality this project
// never calls.
#include <errno.h>
#include <malloc.h>
#include <stddef.h>

extern void smk_clock_init(void); // RCC/PLL bring-up (Task 2, ports/stm32f4/ClockInit.swift)
extern void app_main_swift(void);

int posix_memalign(void **memptr, size_t alignment, size_t size) {
    if (alignment == 0 || (alignment & (alignment - 1)) != 0) return EINVAL;
    if (size == 0) { *memptr = NULL; return 0; }
    void *p = memalign(alignment, size);
    if (p == NULL) return ENOMEM;
    *memptr = p;
    return 0;
}

void _init(void) {}

int main(void) {
    smk_clock_init();
    app_main_swift();
    return 0;
}
