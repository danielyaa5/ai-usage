import Foundation

extension HTTPResponse {
    static func encoded<T: Encodable>(_ value: T, status: Int = 200) -> HTTPResponse {
        let body = (try? StoreTestShared.encoder.encode(value)) ?? Data("{}".utf8)
        return HTTPResponse(status: status, contentType: "application/json", body: body)
    }

}
