import Foundation

nonisolated struct AudiobookAPIFailure: Error, Equatable, Sendable {
    let statusCode: Int
    let detail: String?
    let code: String?

    init(statusCode: Int, detail: String? = nil, code: String? = nil) {
        self.statusCode = statusCode
        self.detail = detail
        self.code = code
    }

    init(statusCode: Int, body: Data) {
        let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        self.init(statusCode: statusCode, detail: Self.text(object?["detail"]), code: Self.text(object?["code"]))
    }

    static func check(_ response: URLResponse, body: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw AudiobookAPIFailure(statusCode: 0)
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            throw AudiobookAPIFailure(statusCode: http.statusCode, body: body)
        }
    }

    private static func text(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
