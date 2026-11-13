import Foundation
import XCTest
@testable import TradingCore

final class PrivateProviderProtocolTests: XCTestCase {
    func testOAuthRequiresExactRedirectAndSingleMatchingStateAndCode() throws {
        let redirect = try XCTUnwrap(URL(string: "stocktracker://angellist-oauth"))
        func code(_ url: String) throws -> String? {
            PrivateProviderProtocol.authorizationCode(in: try XCTUnwrap(URL(string: url)), redirect: redirect, state: "secret")
        }
        XCTAssertEqual(try code("stocktracker://angellist-oauth?code=auth&state=secret"), "auth")
        for invalid in [
            "stocktracker://wrong-host?code=auth&state=secret",
            "stocktracker://angellist-oauth/path?code=auth&state=secret",
            "stocktracker://angellist-oauth?code=auth&state=wrong",
            "stocktracker://angellist-oauth?code=auth&state=secret&state=other",
            "stocktracker://angellist-oauth?code=auth&code=other&state=secret",
            "stocktracker://angellist-oauth?code=auth&state=secret&error=access_denied"
        ] { XCTAssertNil(try code(invalid)) }
    }

    func testReadsMatchingJSONRPCEventAndRefusesErrorsOrMismatchedID() throws {
        let data = Data("""
            : comment

            data: {"jsonrpc":"2.0","method":"notification"}

            event: message
            data: {"jsonrpc":"2.0","id":5,
            data: "result":{"tools":[]}}

            """.utf8)
        let result = try PrivateProviderProtocol.rpcResult(in: data, id: 5, contentType: "text/event-stream")
        XCTAssertNotNil(result["tools"] as? [Any])
        XCTAssertThrowsError(try PrivateProviderProtocol.rpcResult(in: data, id: 6, contentType: "text/event-stream"))
        let failure = Data(#"{"jsonrpc":"2.0","id":5,"error":{"code":-32602,"message":"invalid parameters"}}"#.utf8)
        XCTAssertThrowsError(try PrivateProviderProtocol.rpcResult(in: failure, id: 5, contentType: "application/json"))
    }
}
