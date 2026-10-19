import Foundation

extension String {
    nonisolated var scalarCount: Int {
        unicodeScalars.count
    }

    nonisolated func scalarPrefix(_ maxLength: Int) -> String {
        String(String.UnicodeScalarView(unicodeScalars.prefix(maxLength)))
    }
}
