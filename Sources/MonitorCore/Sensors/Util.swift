import Foundation

/// A NUL-terminated C buffer as a Swift string.
@inline(__always) func cstr(_ buf: [CChar]) -> String {
    let bytes = buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
    return String(decoding: bytes, as: UTF8.self)
}

/// Converts a property-list number of any width to the wanted type.
func num(_ v: Any?) -> Double? {
    switch v {
    case let n as NSNumber: return n.doubleValue
    case let d as Double: return d
    case let i as Int: return Double(i)
    default: return nil
    }
}
func int(_ v: Any?) -> Int? { num(v).map { Int($0) } }
