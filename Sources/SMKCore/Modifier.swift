enum Modifier: UInt8 {
    case leftCtrl
    case leftShift
    case leftAlt
    case leftGUI
    case rightCtrl
    case rightShift
    case rightAlt
    case rightGUI

    var rawValue: UInt8 {
        switch self {
        case .leftCtrl:   return 0b00000001
        case .leftShift:  return 0b00000010
        case .leftAlt:    return 0b00000100
        case .leftGUI:    return 0b00001000
        case .rightCtrl:  return 0b00010000
        case .rightShift: return 0b00100000
        case .rightAlt:   return 0b01000000
        case .rightGUI:   return 0b10000000
        }
    }
}
