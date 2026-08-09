// Thin forwarding header so SPM's `CJSON` host target (see Package.swift)
// can present a single-header umbrella layout — Swift Package Manager's
// umbrella-header auto-detection rejects a publicHeadersPath that has
// directories alongside the matching header, and the real vendored
// managed_components/espressif__cjson/cJSON/ (ESP-IDF's fetched
// component, not tracked in git) is a full upstream checkout with
// fuzzing/, library_config/, tests/ subdirectories next to cJSON.h.
// This just re-exports the vendored header byte-for-byte so tests build
// against the exact same parser the firmware ships.
#include "../../../managed_components/espressif__cjson/cJSON/cJSON.h"
