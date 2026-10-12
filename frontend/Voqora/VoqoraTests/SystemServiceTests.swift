@testable import Voqora
import XCTest

final class SystemServiceTests: XCTestCase {
    func test_beginDucking_withNothingRunning_probesOncePerWindow() {
        let scripts = Box<[String]>([])
        let clock = Box(Date(timeIntervalSince1970: 0))
        let service = SystemService(
            runScript: { source in
                scripts.value.append(source)
                return ("Music=-1", false)
            },
            now: { clock.value },
            installedApps: { ["Music"] }
        )

        for _ in 0 ..< 5 {
            service.beginDucking { _ in }
        }
        service.waitUntilIdleForTesting()

        XCTAssertEqual(scripts.value.count, 1)
    }

    func test_beginDucking_afterWindow_probesAgain() {
        let scripts = Box<[String]>([])
        let clock = Box(Date(timeIntervalSince1970: 0))
        let service = SystemService(
            runScript: { source in
                scripts.value.append(source)
                return ("Music=-1", false)
            },
            now: { clock.value },
            installedApps: { ["Music"] }
        )

        service.beginDucking { _ in }
        service.waitUntilIdleForTesting()
        clock.value = clock.value.addingTimeInterval(11)
        service.beginDucking { _ in }
        service.waitUntilIdleForTesting()

        XCTAssertEqual(scripts.value.count, 2)
    }

    func test_endDucking_restoresSavedVolumes() {
        let scripts = Box<[String]>([])
        let clock = Box(Date(timeIntervalSince1970: 0))
        let service = SystemService(
            runScript: { source in
                scripts.value.append(source)
                return ("Music=40", false)
            },
            now: { clock.value },
            installedApps: { ["Music"] }
        )

        service.beginDucking { _ in }
        service.endDucking()
        service.waitUntilIdleForTesting()

        XCTAssertTrue(scripts.value.last?.contains("set sound volume to 40") ?? false)
    }
}

private final class Box<Value>: @unchecked Sendable {
    var value: Value

    init(_ value: Value) {
        self.value = value
    }
}
