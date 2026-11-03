import Foundation

extension Date {
    /// Xcode 27.2 links Date.>= weakly and the macOS 27.2 Foundation does not provide it, so calling it jumps to null.
    static func >= (lhs: Date, rhs: Date) -> Bool {
        !(lhs < rhs)
    }
}
