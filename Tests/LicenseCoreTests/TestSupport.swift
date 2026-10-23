import Foundation
import XCTest
@testable import LicenseCore

enum Fixtures {
    /// 저장소 루트(이 파일: Tests/LicenseCoreTests/TestSupport.swift)
    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    static func json(_ relativePath: String) throws -> JSONObject {
        let data = try Data(contentsOf: repoRoot.appendingPathComponent(relativePath))
        guard case .object(let o) = try JSONParser.parse(data) else {
            throw NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(relativePath)는 JSON 객체가 아닙니다"])
        }
        return o
    }

    static func utc(_ s: String) -> Date { LicenseTime.parseUTC(s)! }
}

extension JSONValue {
    subscript(_ key: String) -> JSONValue? { objectValue?[key] }
    var arrayValue: [JSONValue] {
        if case .array(let a) = self { return a }
        return []
    }
}
