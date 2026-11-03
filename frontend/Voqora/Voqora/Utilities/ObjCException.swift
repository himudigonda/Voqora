import Foundation

nonisolated struct ObjCExceptionError: Error, Equatable {
    let reason: String
}

nonisolated enum ObjCException {
    static func catching(_ body: () -> Void) throws {
        if let reason = VQReasonForExceptionIn(body) {
            throw ObjCExceptionError(reason: reason)
        }
    }
}
