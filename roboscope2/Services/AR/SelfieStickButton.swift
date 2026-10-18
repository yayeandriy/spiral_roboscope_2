//
//  SelfieStickButton.swift
//  roboscope2
//
//  Bluetooth selfie-stick shutter for the laser-guide inspection session.
//  A short press places a marker. A double press deletes a hovered marker
//  or starts origin adjustment. Holding runs origin detection, the same
//  as holding the on-screen origin button.
//
//  Sticks report themselves as a volume-up key. While the AR camera is
//  running, iOS delivers that as a capture event with a real press and
//  release. Sticks that never become capture events still move the system
//  volume; those repeats are the fallback.
//

import AVFoundation
import AVKit
import MediaPlayer
import UIKit

enum SelfieStickButtonEvent: Equatable {
    /// Short press. The session places a marker when one can be placed.
    case click
    /// Two presses, then the button stays up. Not a hold.
    case doubleClick
    /// Press crossed into a hold (or origin detection is the only action).
    case holdBegan
    /// Hold released.
    case holdEnded
}

/// Classifies a shutter press without knowing about timers or hardware.
///
/// A selfie-stick shutter often emits a short click, then repeats that click
/// while the button is held. `up` is therefore not a release. The press ends
/// only on `releaseGap`, after the clicks stop.
struct SelfieStickGestureMachine {

    enum Input: Equatable {
        /// Press down, or another click while the button is still held.
        case down
        /// Capture event ended. A repeating stick sends this between clicks.
        case up
        /// The capture button is still down (no `up` yet) past the hold delay.
        case holdThreshold
        /// No further clicks arrived. The button is up.
        case releaseGap
    }

    /// When true, the press is origin detection immediately. Used before an
    /// origin exists, when there is no marker action to protect.
    var immediateHold = false

    enum Source: Equatable {
        case capture
        case volume
    }

    private enum Phase: Equatable {
        case idle
        case pending
        case holding
    }

    private var phase: Phase = .idle
    private var source: Source?
    /// True after a capture `up`. The button may still be physically held if another `down` arrives.
    private var sawUp = false
    /// Presses since idle. Two, then silence, is a double click. A third is a hold.
    private var presses = 0

    var isIdle: Bool {
        if case .idle = phase { return true }
        return false
    }

    /// What the hardware adapter should keep armed after the latest input.
    enum TimerNeed: Equatable {
        case none
        /// Capture press is still down. Promote to a hold if it stays there.
        case shutterHold
        /// Wait to see if the stick clicks again before treating the button as released.
        case releaseGap(TimeInterval)
    }

    var timerNeed: TimerNeed {
        switch phase {
        case .idle:
            return .none
        case .pending where source == .capture && !sawUp:
            return .shutterHold
        case .pending, .holding:
            if source == .volume || sawUp {
                return .releaseGap(silenceInterval)
            }
            return .none
        }
    }

    /// How long to wait after the last pulse before the gesture is finished.
    /// One press waits long enough for a second click. Two presses wait only
    /// long enough to see the next repeat of a held shutter.
    private var silenceInterval: TimeInterval {
        if source == .volume { return 0.65 }
        return presses <= 1 ? 0.35 : 0.22
    }

    mutating func handle(_ input: Input) -> [SelfieStickButtonEvent] {
        switch input {
        case .down:
            return down()
        case .up:
            return up()
        case .holdThreshold:
            return promoteHold()
        case .releaseGap:
            return finish()
        }
    }

    /// Leaves the gesture. A hold still in progress ends; a press that never
    /// became a hold does not place a marker.
    mutating func cancel() -> [SelfieStickButtonEvent] {
        let wasHolding = phase == .holding
        reset()
        return wasHolding ? [.holdEnded] : []
    }

    private mutating func down() -> [SelfieStickButtonEvent] {
        switch phase {
        case .idle:
            source = source ?? .capture
            sawUp = false
            presses = 1
            if immediateHold {
                phase = .holding
                return [.holdBegan]
            }
            phase = .pending
            return []
        case .pending where sawUp || source == .volume:
            presses += 1
            sawUp = false
            // A held shutter repeats. Two presses can still be a double click.
            guard presses >= 3 else { return [] }
            phase = .holding
            return [.holdBegan]
        case .pending, .holding:
            sawUp = false
            return []
        }
    }

    /// Marks which hardware path produced the next `down` from idle.
    mutating func beginDown(from newSource: Source) -> [SelfieStickButtonEvent] {
        if phase == .idle {
            source = newSource
        } else if newSource == .capture, source == .volume {
            source = .capture
        } else if newSource == .volume, source == .capture {
            return []
        }
        return down()
    }

    private mutating func up() -> [SelfieStickButtonEvent] {
        guard phase != .idle else { return [] }
        sawUp = true
        return []
    }

    private mutating func promoteHold() -> [SelfieStickButtonEvent] {
        guard phase == .pending, !sawUp else { return [] }
        phase = .holding
        return [.holdBegan]
    }

    private mutating func finish() -> [SelfieStickButtonEvent] {
        let wasHolding = phase == .holding
        let count = presses
        guard phase != .idle else { return [] }
        reset()
        if wasHolding { return [.holdEnded] }
        return count >= 2 ? [.doubleClick] : [.click]
    }

    private mutating func reset() {
        phase = .idle
        source = nil
        sawUp = false
        presses = 0
    }
}

/// Listens for the stick and turns hardware signals into click / hold events.
final class SelfieStickButtonController: NSObject {

    var immediateHold = false
    var onEvent: (SelfieStickButtonEvent) -> Void = { _ in }

    private var machine = SelfieStickGestureMachine()
    private var started = false
    private var acceptsInput = true
    private var generation = 0
    private var cooldownUntil: CFTimeInterval = 0

    private var holdTimer: Timer?
    private var silenceTimer: Timer?
    private var volumeObservation: NSKeyValueObservation?
    private var volumeView: MPVolumeView?
    private var originalVolume: Float?
    private var lastSetVolume: Float?
    /// Once iOS delivers shutter events, volume changes are the system volume
    /// (Control Center), not the stick. Leave them alone.
    private var captureEventsSeen = false

    /// Capture press still down. Shorter than a stick's click-repeat gap.
    private let shutterHoldDelay: TimeInterval = 0.20
    private let postGestureCooldown: TimeInterval = 0.15

    func start() {
        guard !started else { return }
        let generation = self.generation
        guard keyWindow() != nil else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self, self.generation == generation, !self.started else { return }
                self.start()
            }
            return
        }
        started = true
        originalVolume = AVAudioSession.sharedInstance().outputVolume
        installVolumeView()
        observeVolume()
    }

    func stop() {
        generation += 1
        guard started else { return }
        started = false
        acceptsInput = false
        deliver(machine.cancel())
        syncTimers()
        volumeObservation?.invalidate()
        volumeObservation = nil
        restoreVolume()
        volumeView?.removeFromSuperview()
        volumeView = nil
    }

    /// When false, an in-progress hold ends and further presses are ignored
    /// so the system volume buttons work again (menus, manual placement).
    func setAcceptsInput(_ accepts: Bool) {
        guard accepts != acceptsInput else { return }
        acceptsInput = accepts
        guard !accepts else { return }
        deliver(machine.cancel())
        syncTimers()
    }

    func handleCapturePhase(_ phase: AVCaptureEventPhase) {
        guard acceptsInput else { return }
        captureEventsSeen = true
        switch phase {
        case .began:
            ingestDown(from: .capture)
        case .ended, .cancelled:
            ingest(.up)
        @unknown default:
            break
        }
    }

    private func ingestDown(from source: SelfieStickGestureMachine.Source) {
        if machine.isIdle, CACurrentMediaTime() < cooldownUntil {
            return
        }
        machine.immediateHold = immediateHold
        let events = machine.beginDown(from: source)
        syncTimers()
        deliver(events)
    }

    private func ingest(_ input: SelfieStickGestureMachine.Input) {
        if machine.isIdle, CACurrentMediaTime() < cooldownUntil {
            return
        }
        machine.immediateHold = immediateHold
        let events = machine.handle(input)
        syncTimers()
        if events.contains(.click) || events.contains(.doubleClick) || events.contains(.holdEnded) {
            cooldownUntil = CACurrentMediaTime() + postGestureCooldown
        }
        deliver(events)
    }

    private func deliver(_ events: [SelfieStickButtonEvent]) {
        for event in events {
            onEvent(event)
        }
    }

    private func syncTimers() {
        switch machine.timerNeed {
        case .none:
            invalidateTimers()
        case .shutterHold:
            silenceTimer?.invalidate()
            silenceTimer = nil
            guard holdTimer == nil else { return }
            let timer = Timer(timeInterval: shutterHoldDelay, repeats: false) { [weak self] _ in
                self?.holdTimer = nil
                self?.ingest(.holdThreshold)
            }
            holdTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        case .releaseGap(let interval):
            holdTimer?.invalidate()
            holdTimer = nil
            silenceTimer?.invalidate()
            let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
                self?.silenceTimer = nil
                self?.ingest(.releaseGap)
            }
            silenceTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    private func invalidateTimers() {
        holdTimer?.invalidate()
        holdTimer = nil
        silenceTimer?.invalidate()
        silenceTimer = nil
    }

    // MARK: - Volume fallback

    private func installVolumeView() {
        guard volumeView == nil, let window = keyWindow() else { return }
        let view = MPVolumeView(frame: CGRect(x: -120, y: -120, width: 80, height: 20))
        view.alpha = 0.01
        view.isUserInteractionEnabled = false
        window.addSubview(view)
        volumeView = view
    }

    private func observeVolume() {
        volumeObservation = AVAudioSession.sharedInstance().observe(\.outputVolume, options: [.new, .old]) { [weak self] _, change in
            let newValue = change.newValue ?? 0
            let oldValue = change.oldValue ?? newValue
            DispatchQueue.main.async {
                self?.handleOutputVolume(new: newValue, old: oldValue)
            }
        }
    }

    private func restoreVolume() {
        guard lastSetVolume != nil, let originalVolume else { return }
        setSystemVolume(originalVolume)
        self.originalVolume = nil
    }

    private func handleOutputVolume(new: Float, old: Float) {
        if let lastSetVolume, abs(new - lastSetVolume) < 0.02 {
            return
        }
        guard started, acceptsInput, !captureEventsSeen else { return }
        guard abs(new - old) > 0.001 else { return }
        // Put the level back so a stick press does not leave the volume changed,
        // and so a held key can keep repeating instead of hitting the rail.
        setSystemVolume(old)
        ingestDown(from: .volume)
    }

    private func setSystemVolume(_ value: Float) {
        guard let slider = volumeSlider else { return }
        lastSetVolume = value
        slider.setValue(value, animated: false)
    }

    private var volumeSlider: UISlider? {
        guard let volumeView else { return nil }
        return findSlider(in: volumeView)
    }

    private func findSlider(in view: UIView) -> UISlider? {
        if let slider = view as? UISlider { return slider }
        for subview in view.subviews {
            if let slider = findSlider(in: subview) { return slider }
        }
        return nil
    }

    private func keyWindow() -> UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
    }
}
