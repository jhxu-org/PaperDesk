import Foundation
import PaperDeskCore

extension PaperDeskCoreTests {
    func testNetworkPrivacy(baseURL: String) async throws {
        guard let url = URL(string: baseURL), url.host == "127.0.0.1", url.scheme == "http" else {
            throw CheckFailure(description: "Privacy fixture must be a loopback server")
        }
        let client = AIClient()
        // Test both URLSession data and bytes paths using the production session.
        for stream in [false, true] {
            for path in ["direct", "same"] {
                let config = APIConfiguration(baseURL: baseURL + "/" + path + "/v1", model: "synthetic", apiKey: "fixture-only", streamResponses: stream)
                try await client.testConnection(configuration: config)
                try await client.testConnection(configuration: config)
            }
            for path in ["other-port", "other-host"] {
                let config = APIConfiguration(baseURL: baseURL + "/" + path + "/v1", model: "synthetic", apiKey: "fixture-only", streamResponses: stream)
                do { try await client.testConnection(configuration: config); try XCTFail("Cross-origin redirect completed") }
                catch let error as PaperDeskError { try XCTAssertTrue(error.localizedDescription.contains("已阻止")) }
            }
        }
    }
}
