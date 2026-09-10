import Foundation
import Testing
@testable import SuzuiOS

struct SuzuiOSTests {
    // テストは TEST_HOST (SuzuiOS.app) の中で走るため、Bundle.main がアプリ本体を指すことで
    // 雛形の target 構成 (hosted unit test) が CI でも成立していることを確かめる
    @Test func testsRunInsideApp() {
        #expect(Bundle.main.bundleIdentifier == "com.bannzai.SuzuiOS")
    }
}
