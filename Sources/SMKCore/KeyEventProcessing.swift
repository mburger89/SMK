struct KeyPosition: Equatable {
    let row: Int
    let col: Int
}

struct KeyTransition: Equatable {
    let position: KeyPosition
    let pressed: Bool
}

enum ConnectionToggleEvent: Equatable {
    case toggled(ConnectionMode)
    case ignored
}

struct KeyEventProcessingResult {
    var report = HIDReport()
    var transitions: [KeyTransition] = []
    var connectionModeChanged = false
    var connectionToggleIgnored = false
    var connectionEvents: [ConnectionToggleEvent] = []
}

/// Processes one debounced scan cycle against the current layer/connection
/// state: resolves press/release transitions (mutating `pressedActions`
/// and `engine`'s momentary/toggled layer state in place), decides
/// whether a `toggle_conn` press should flip `currentMode` (only when
/// `hasWiredBridge`), and assembles the resulting HID report from
/// currently-held keys. Pure data in/out — no hardware or logging calls;
/// callers use `transitions` (in scan-index order, matching the original
/// inline loop) to drive RGB, and `connectionEvents` (also in scan-index
/// order, one entry per toggle_conn press-transition, each capturing
/// `currentMode`'s value at that specific toggle instant) to drive
/// logging — replaying it reproduces the exact log sequence the original
/// inline-per-press logging produced, even if a future keymap binds
/// toggle_conn to multiple keys that transition in the same cycle.
/// `connectionModeChanged`/`connectionToggleIgnored` remain as
/// simple last-write-wins summary flags for callers that only care
/// whether *any* toggle/ignore happened this cycle.
func processKeyEvents(
    cleanScan: [Bool],
    lastScan: [Bool],
    colCount: Int,
    pressedActions: inout [KeyAction],
    engine: inout LayerEngine,
    hasWiredBridge: Bool,
    currentMode: inout ConnectionMode
) -> KeyEventProcessingResult {
    var result = KeyEventProcessingResult()

    for i in 0..<cleanScan.count {
        let row = i / colCount
        let col = i % colCount

        if cleanScan[i] && !lastScan[i] {
            let action = engine.getAction(row: row, col: col)
            pressedActions[i] = action
            result.transitions.append(KeyTransition(position: KeyPosition(row: row, col: col), pressed: true))

            switch action {
            case .toggleLayer(let l):
                engine.toggleLayer(l)
            case .momentaryLayer(let l):
                engine.addMomentaryLayer(l)
            case .toggleConnection:
                if hasWiredBridge {
                    currentMode.toggle()
                    result.connectionModeChanged = true
                    result.connectionEvents.append(.toggled(currentMode))
                } else {
                    result.connectionToggleIgnored = true
                    result.connectionEvents.append(.ignored)
                }
            default:
                break
            }
        } else if lastScan[i] && !cleanScan[i] {
            let action = pressedActions[i]
            result.transitions.append(KeyTransition(position: KeyPosition(row: row, col: col), pressed: false))

            switch action {
            case .momentaryLayer(let l):
                engine.removeMomentaryLayer(l)
            default:
                break
            }
            pressedActions[i] = .none
        }
    }

    for i in 0..<cleanScan.count {
        if cleanScan[i] {
            switch pressedActions[i] {
            case .key(let code):
                result.report.addKey(code.rawValue)
            case .modifier(let mod):
                result.report.addModifier(mod)
            default:
                break
            }
        }
    }

    return result
}
