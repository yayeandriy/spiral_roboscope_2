//
//  SelfieStickButtonTests.swift
//  roboscope2Tests
//

import XCTest
@testable import roboscope2

final class SelfieStickButtonTests: XCTestCase {

    func testTapIsAClickOnceTheClicksStop() {
        var machine = SelfieStickGestureMachine()
        XCTAssertEqual(machine.handle(.down), [])
        XCTAssertEqual(machine.handle(.up), [])
        // The button came up before the hold delay. A late threshold must not start origin.
        XCTAssertEqual(machine.handle(.holdThreshold), [])
        XCTAssertEqual(machine.handle(.releaseGap), [.click])
        XCTAssertTrue(machine.isIdle)
    }

    func testSustainedHoldStartsOriginAndDoesNotClick() {
        var machine = SelfieStickGestureMachine()
        XCTAssertEqual(machine.handle(.down), [])
        XCTAssertEqual(machine.timerNeed, .shutterHold)
        XCTAssertEqual(machine.handle(.holdThreshold), [.holdBegan])
        XCTAssertEqual(machine.timerNeed, .none)
        XCTAssertEqual(machine.handle(.up), [])
        XCTAssertEqual(machine.handle(.releaseGap), [.holdEnded])
        XCTAssertTrue(machine.isIdle)
    }

    func testRepeatingClicksWhileHeldAreOneHold() {
        var machine = SelfieStickGestureMachine()
        XCTAssertEqual(machine.handle(.down), [])
        XCTAssertEqual(machine.handle(.up), [])
        // A second click can still be a double tap. The third repeat is a hold.
        XCTAssertEqual(machine.handle(.down), [])
        XCTAssertEqual(machine.handle(.up), [])
        XCTAssertEqual(machine.handle(.down), [.holdBegan])
        XCTAssertEqual(machine.handle(.up), [])
        XCTAssertEqual(machine.handle(.releaseGap), [.holdEnded])
    }

    func testTwoClicksAreADoubleClickAndNotAHold() {
        var machine = SelfieStickGestureMachine()
        XCTAssertEqual(machine.handle(.down), [])
        XCTAssertEqual(machine.handle(.up), [])
        XCTAssertEqual(machine.handle(.down), [])
        XCTAssertEqual(machine.handle(.up), [])
        XCTAssertEqual(machine.handle(.releaseGap), [.doubleClick])
        XCTAssertTrue(machine.isIdle)
    }

    func testImmediateHoldSurvivesTheFirstClickPulse() {
        var machine = SelfieStickGestureMachine()
        machine.immediateHold = true
        XCTAssertEqual(machine.handle(.down), [.holdBegan])
        // A stick's first click ends immediately. That must not release origin detection.
        XCTAssertEqual(machine.handle(.up), [])
        XCTAssertEqual(machine.handle(.releaseGap), [.holdEnded])
    }

    func testVolumeTapIsAClick() {
        var machine = SelfieStickGestureMachine()
        XCTAssertEqual(machine.beginDown(from: .volume), [])
        if case .releaseGap = machine.timerNeed {} else {
            XCTFail("volume press should wait out the repeat gap, got \(machine.timerNeed)")
        }
        XCTAssertEqual(machine.handle(.releaseGap), [.click])
    }

    func testVolumeRepeatIsAHold() {
        var machine = SelfieStickGestureMachine()
        XCTAssertEqual(machine.beginDown(from: .volume), [])
        XCTAssertEqual(machine.beginDown(from: .volume), [])
        XCTAssertEqual(machine.handle(.releaseGap), [.doubleClick])
    }

    func testVolumeKeepsRepeatingIntoAHold() {
        var machine = SelfieStickGestureMachine()
        XCTAssertEqual(machine.beginDown(from: .volume), [])
        XCTAssertEqual(machine.beginDown(from: .volume), [])
        XCTAssertEqual(machine.beginDown(from: .volume), [.holdBegan])
        XCTAssertEqual(machine.handle(.releaseGap), [.holdEnded])
    }

    func testVolumeTicksDoNotJoinACapturePress() {
        var machine = SelfieStickGestureMachine()
        XCTAssertEqual(machine.handle(.down), [])
        XCTAssertEqual(machine.beginDown(from: .volume), [])
        XCTAssertEqual(machine.timerNeed, .shutterHold)
        XCTAssertEqual(machine.handle(.up), [])
        XCTAssertEqual(machine.handle(.releaseGap), [.click])
    }

    func testCaptureTakeoverDoesNotDoubleFire() {
        var machine = SelfieStickGestureMachine()
        XCTAssertEqual(machine.beginDown(from: .volume), [])
        XCTAssertEqual(machine.beginDown(from: .capture), [])
        XCTAssertEqual(machine.handle(.holdThreshold), [.holdBegan])
        XCTAssertEqual(machine.handle(.up), [])
        XCTAssertEqual(machine.handle(.releaseGap), [.holdEnded])
    }

    func testCancelPendingDoesNotClick() {
        var machine = SelfieStickGestureMachine()
        _ = machine.handle(.down)
        XCTAssertEqual(machine.cancel(), [])
        XCTAssertTrue(machine.isIdle)
        XCTAssertEqual(machine.handle(.releaseGap), [])
    }

    func testCancelHoldingEndsTheHold() {
        var machine = SelfieStickGestureMachine()
        machine.immediateHold = true
        _ = machine.handle(.down)
        XCTAssertEqual(machine.cancel(), [.holdEnded])
        XCTAssertTrue(machine.isIdle)
    }
}
