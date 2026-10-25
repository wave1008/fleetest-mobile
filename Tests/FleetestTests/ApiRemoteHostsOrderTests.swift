// `fleetest api remote-machines --order`(設定タブの↑ボタンが拡張経由で撃つ)。
// 書き込み操作は1回の呼び出しに1つだけ(どれを先に適用したかで結果が変わるため)。
// run() は ~/.config/fleetest/config.json を読み書きするので、ここでは解析と値の読み取りだけを試す

import XCTest
@testable import fleetest

final class ApiRemoteHostsOrderTests: XCTestCase {

    func testOrderAloneIsAccepted() throws {
        let command = try ApiRemoteHostsCommand.parse(["--order", "M1Ultra,M1Max"])
        XCTAssertEqual(command.order, "M1Ultra,M1Max")
    }

    func testOrderCannotBeCombinedWithOtherWrites() {
        for args in [["--order", "a", "--remove", "b"],
                     ["--order", "a", "--import", "[]"],
                     ["--import", "[]", "--remove", "b"]] {
            XCTAssertThrowsError(try ApiRemoteHostsCommand.parse(args), "\(args)") { error in
                XCTAssertTrue(ApiRemoteHostsCommand.message(for: error).contains("cannot be combined"),
                              ApiRemoteHostsCommand.message(for: error))
            }
        }
    }

    func testOrderNamesSplitsOnCommasAndDropsBlanks() {
        XCTAssertEqual(ApiRemoteHostsCommand.orderNames("M1Ultra,M1Max"), ["M1Ultra", "M1Max"])
        XCTAssertEqual(ApiRemoteHostsCommand.orderNames(" a , b ,,c "), ["a", "b", "c"])
        XCTAssertEqual(ApiRemoteHostsCommand.orderNames(""), [])
        // split は空の要素を返さないが、空白だけの要素は trim の後に空になる
        XCTAssertEqual(ApiRemoteHostsCommand.orderNames("a, ,b"), ["a", "b"])
    }
}
