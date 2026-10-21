import Foundation

nonisolated struct MultipartForm: Sendable {
    let boundary: String
    private(set) var body = Data()

    init(boundary: String = "Boundary-\(UUID().uuidString)") {
        self.boundary = boundary
    }

    var contentType: String {
        "multipart/form-data; boundary=\(boundary)"
    }

    func appending(field name: String, value: String) -> MultipartForm {
        var copy = self
        copy.body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(Self.escaped(name))\"\r\n\r\n\(value)\r\n".utf8))
        return copy
    }

    func appending(file name: String, filename: String, mimeType: String, data: Data) -> MultipartForm {
        var copy = self
        let header = "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(Self.escaped(name))\"; filename=\"\(Self.escaped(filename))\"\r\nContent-Type: \(mimeType)\r\n\r\n"
        copy.body.append(Data(header.utf8))
        copy.body.append(data)
        copy.body.append(Data("\r\n".utf8))
        return copy
    }

    func finished() -> MultipartForm {
        var copy = self
        copy.body.append(Data("--\(boundary)--\r\n".utf8))
        return copy
    }

    private static func escaped(_ value: String) -> String {
        value.filter { !"\"\r\n".contains($0) }
    }
}
