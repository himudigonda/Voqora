@testable import Voqora
import XCTest

final class SpeechSourceTests: XCTestCase {
    func test_defaultSourceIsApp() {
        XCTAssertEqual(SpeechSource.current, .app)
    }

    func test_taskLocalPropagatesIntoUnstructuredTask() async {
        let seen = await SpeechSource.$current.withValue(.clipboard) {
            await Task { SpeechSource.current }.value
        }
        XCTAssertEqual(seen, .clipboard)
    }

    func test_detachedTaskDoesNotInheritTheSource() async {
        let captured = await SpeechSource.$current.withValue(.relay) { SpeechSource.current }
        let detached = await SpeechSource.$current.withValue(.relay) {
            await Task.detached { SpeechSource.current }.value
        }
        XCTAssertEqual(captured, .relay)
        XCTAssertEqual(detached, .app)
    }

    func test_nestedScopesRestoreTheOuterValue() async {
        await SpeechSource.$current.withValue(.inbox) {
            await SpeechSource.$current.withValue(.sample) {
                XCTAssertEqual(SpeechSource.current, .sample)
            }
            XCTAssertEqual(SpeechSource.current, .inbox)
        }
        XCTAssertEqual(SpeechSource.current, .app)
    }

    func test_everySourceHasATitleAndAContractValue() {
        for source in SpeechSource.allCases {
            XCTAssertFalse(source.title.isEmpty)
            XCTAssertTrue(MetricsService.Bucket.sources.contains(source.rawValue))
        }
        XCTAssertEqual(SpeechSource.allCases.count, 11)
    }
}
