#include <stdint.h>
#include <stddef.h>

extern void app_main_swift(void);

// Unicode stubs to satisfy the linker for Embedded Swift String usage
void _swift_stdlib_getNormData(void) {}
void _swift_stdlib_getComposition(void) {}
void _swift_stdlib_getDecompositionEntry(void) {}
uint8_t *_swift_stdlib_nfd_decompositions = NULL;
void _swift_stdlib_isExtendedPictographic(void) {}
void _swift_stdlib_isInCB_Consonant(void) {}
void _swift_stdlib_getGraphemeBreakProperty(void) {}

void app_main(void) {
    app_main_swift();
}
