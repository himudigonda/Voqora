@testable import Voqora
import XCTest

/// Pure breakpoint tests for MainDashboardLayout (the v1.1 design notes Sprint 6, T6.4).
final class MainDashboardLayoutTests: XCTestCase {
    func test_wideWidth_usesRegularMetrics() {
        let m = MainDashboardLayout.metrics(for: 1200)
        XCTAssertEqual(m.ambientCircleSize, 450)
        XCTAssertEqual(m.outerRingSize, 260)
        XCTAssertEqual(m.innerRingSize, 200)
        XCTAssertEqual(m.headerPadding, 40)
        XCTAssertEqual(m.sliderHorizontalPadding, 100)
    }

    func test_narrowWidth_usesCompactMetrics() {
        let m = MainDashboardLayout.metrics(for: 500)
        XCTAssertEqual(m.ambientCircleSize, 300)
        XCTAssertEqual(m.outerRingSize, 180)
        XCTAssertEqual(m.innerRingSize, 140)
        XCTAssertEqual(m.headerPadding, 20)
        XCTAssertEqual(m.sliderHorizontalPadding, 30)
    }

    func test_atCompactBreakpoint_usesRegularMetrics() {
        // >= the breakpoint stays regular; only strictly-below is compact.
        let atBreakpoint = MainDashboardLayout.metrics(for: MainDashboardLayout.compactBreakpoint)
        let wide = MainDashboardLayout.metrics(for: 1200)
        XCTAssertEqual(atBreakpoint, wide)
    }

    func test_justBelowCompactBreakpoint_usesCompactMetrics() {
        let justBelow = MainDashboardLayout.metrics(for: MainDashboardLayout.compactBreakpoint - 1)
        let narrow = MainDashboardLayout.metrics(for: 500)
        XCTAssertEqual(justBelow, narrow)
    }

    func test_negativeWidth_isClampedToCompactMetrics() {
        let negative = MainDashboardLayout.metrics(for: -50)
        let narrow = MainDashboardLayout.metrics(for: 500)
        XCTAssertEqual(negative, narrow)
    }

    func test_compactMetrics_areSmallerThanRegularInEveryDimension() {
        let compact = MainDashboardLayout.metrics(for: 0)
        let regular = MainDashboardLayout.metrics(for: 5000)
        XCTAssertLessThan(compact.ambientCircleSize, regular.ambientCircleSize)
        XCTAssertLessThan(compact.outerRingSize, regular.outerRingSize)
        XCTAssertLessThan(compact.innerRingSize, regular.innerRingSize)
        XCTAssertLessThan(compact.headerPadding, regular.headerPadding)
        XCTAssertLessThan(compact.sliderHorizontalPadding, regular.sliderHorizontalPadding)
    }

    func test_ringSizes_stayNestedInBothTiers() {
        // outerRingSize must stay larger than innerRingSize in both tiers,
        // or the two visualizer rings would render inverted/overlapping.
        let compact = MainDashboardLayout.metrics(for: 0)
        let regular = MainDashboardLayout.metrics(for: 5000)
        XCTAssertGreaterThan(compact.outerRingSize, compact.innerRingSize)
        XCTAssertGreaterThan(regular.outerRingSize, regular.innerRingSize)
    }
}
