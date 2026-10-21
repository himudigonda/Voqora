@testable import Voqora
import XCTest

@MainActor
final class PasteboardGateTests: XCTestCase {
    func test_secondHolderWaitsUntilTheFirstReleases() async {
        let gate = PasteboardGate()
        var order: [String] = []
        await gate.acquire()
        let second = Task {
            await gate.acquire()
            order.append("second")
            gate.release()
        }
        for _ in 0 ..< 20 {
            await Task.yield()
        }
        order.append("first")
        gate.release()
        await second.value

        XCTAssertEqual(order, ["first", "second"])
    }

    func test_waitersAreServedInArrivalOrder() async {
        let gate = PasteboardGate()
        var order: [Int] = []
        await gate.acquire()
        let tasks = (1 ... 3).map { index in
            Task {
                await gate.acquire()
                order.append(index)
                gate.release()
            }
        }
        for _ in 0 ..< 20 {
            await Task.yield()
        }
        gate.release()
        for task in tasks {
            await task.value
        }

        XCTAssertEqual(order, [1, 2, 3])
    }

    func test_gateCanBeAcquiredAgainAfterRelease() async {
        let gate = PasteboardGate()
        await gate.acquire()
        gate.release()
        await gate.acquire()
        gate.release()
    }
}
