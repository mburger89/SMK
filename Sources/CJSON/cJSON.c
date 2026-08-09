// Thin forwarding source, see Sources/CJSON/include/cJSON.h for why this
// shim exists. Textually includes the vendored cJSON.c so the host test
// build compiles the exact same parser the firmware ships, without
// duplicating its contents. The vendored file's own `#include "cJSON.h"`
// resolves relative to its own directory (standard C quote-include
// search rules), so it still finds its sibling header there, not this
// forwarding one.
#include "../../managed_components/espressif__cjson/cJSON/cJSON.c"
