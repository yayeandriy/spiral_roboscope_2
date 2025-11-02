//
//  TwoFingerTouchOverlay.swift
//  roboscope2
//
//  Extracted touch overlay to detect one/two finger gestures over ARView while passthrough.
//

import SwiftUI
import UIKit

struct TwoFingerTouchOverlay: UIViewRepresentable {
    let onStart: () -> Void
    let onOneFingerStart: () -> Void
    let onOneFingerEnd: () -> Void
    let onChange: (CGSize, CGFloat) -> Void
    let onEnd: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onStart: onStart, onOneFingerStart: onOneFingerStart, onOneFingerEnd: onOneFingerEnd, onChange: onChange, onEnd: onEnd) }

    func makeUIView(context: Context) -> UIView {
        let touchView = TouchPassthroughView()
        touchView.backgroundColor = .clear
        touchView.isUserInteractionEnabled = true
        touchView.coordinator = context.coordinator
        let pinch = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePinch(_:)))
        pinch.cancelsTouchesInView = false
        pinch.delegate = context.coordinator
        touchView.addGestureRecognizer(pinch)
        return touchView
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        if let touchView = uiView as? TouchPassthroughView {
            touchView.coordinator = context.coordinator
        }
    }

    class TouchPassthroughView: UIView {
        weak var coordinator: Coordinator?
        
        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            super.touchesBegan(touches, with: event)
            coordinator?.handleTouchesBegan(touches, event: event, in: self)
        }
        
        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            super.touchesMoved(touches, with: event)
            coordinator?.handleTouchesMoved(touches, event: event, in: self)
        }
        
        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            super.touchesEnded(touches, with: event)
            coordinator?.handleTouchesEnded(touches, event: event, in: self)
        }
        
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
            super.touchesCancelled(touches, with: event)
            coordinator?.handleTouchesCancelled(touches, event: event, in: self)
        }
    }

    class Coordinator: NSObject, UIGestureRecognizerDelegate {
        let onStart: () -> Void
        let onOneFingerStart: () -> Void
        let onOneFingerEnd: () -> Void
        let onChange: (CGSize, CGFloat) -> Void
        let onEnd: () -> Void
        private var twoFingerActive = false
        private var oneFingerActive = false
        private var oneFingerPending: Timer?
        private var currentScale: CGFloat = 1.0
        private var currentTranslation: CGSize = .zero
        private var trackingTouches: Set<UITouch> = []
        private var touchStartLocation: CGPoint = .zero

        init(onStart: @escaping () -> Void, onOneFingerStart: @escaping () -> Void, onOneFingerEnd: @escaping () -> Void, onChange: @escaping (CGSize, CGFloat) -> Void, onEnd: @escaping () -> Void) {
            self.onStart = onStart
            self.onOneFingerStart = onOneFingerStart
            self.onOneFingerEnd = onOneFingerEnd
            self.onChange = onChange
            self.onEnd = onEnd
        }
        
        func handleTouchesBegan(_ touches: Set<UITouch>, event: UIEvent?, in view: UIView) {
            trackingTouches.formUnion(touches)
            let touchCount = trackingTouches.count
            
            if touchCount == 1, let touch = trackingTouches.first {
                touchStartLocation = touch.location(in: view)
                currentTranslation = .zero
                if !twoFingerActive && !oneFingerActive && oneFingerPending == nil {
                    oneFingerPending = Timer.scheduledTimer(withTimeInterval: 0.18, repeats: false) { [weak self] _ in
                        guard let self = self else { return }
                        if !self.twoFingerActive && !self.oneFingerActive && self.trackingTouches.count == 1 {
                            self.oneFingerActive = true
                            self.onOneFingerStart()
                        }
                    }
                }
            } else if touchCount >= 2 {
                oneFingerPending?.invalidate(); oneFingerPending = nil
                if oneFingerActive {
                    oneFingerActive = false
                    onOneFingerEnd()
                }
                if !twoFingerActive {
                    if let first = trackingTouches.first, let second = trackingTouches.dropFirst().first {
                        let loc1 = first.location(in: view)
                        let loc2 = second.location(in: view)
                        touchStartLocation = CGPoint(x: (loc1.x + loc2.x)/2, y: (loc1.y + loc2.y)/2)
                    }
                    twoFingerActive = true
                    currentScale = 1.0
                    currentTranslation = .zero
                    onStart()
                    onChange(currentTranslation, currentScale)
                }
            }
        }
        
        func handleTouchesMoved(_ touches: Set<UITouch>, event: UIEvent?, in view: UIView) {
            let touchCount = trackingTouches.count
            if touchCount == 1, let touch = trackingTouches.first, oneFingerActive && !twoFingerActive {
                let currentLoc = touch.location(in: view)
                currentTranslation = CGSize(width: currentLoc.x - touchStartLocation.x, height: currentLoc.y - touchStartLocation.y)
                onChange(currentTranslation, currentScale)
            } else if touchCount >= 2 && twoFingerActive {
                if let first = trackingTouches.first, let second = trackingTouches.dropFirst().first {
                    let loc1 = first.location(in: view)
                    let loc2 = second.location(in: view)
                    let centroid = CGPoint(x: (loc1.x + loc2.x)/2, y: (loc1.y + loc2.y)/2)
                    currentTranslation = CGSize(width: centroid.x - touchStartLocation.x, height: centroid.y - touchStartLocation.y)
                    onChange(currentTranslation, currentScale)
                }
            }
        }
        
        func handleTouchesEnded(_ touches: Set<UITouch>, event: UIEvent?, in view: UIView) {
            trackingTouches.subtract(touches)
            let remaining = trackingTouches.count
            
            if remaining == 0 {
                oneFingerPending?.invalidate(); oneFingerPending = nil
                if oneFingerActive {
                    oneFingerActive = false
                    onOneFingerEnd()
                }
                if twoFingerActive {
                    twoFingerActive = false
                    onEnd()
                }
                currentTranslation = .zero
                currentScale = 1.0
            } else if remaining == 1 && twoFingerActive {
                twoFingerActive = false
                onEnd()
            }
        }
        
        func handleTouchesCancelled(_ touches: Set<UITouch>, event: UIEvent?, in view: UIView) {
            handleTouchesEnded(touches, event: event, in: view)
        }

        @objc func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
            currentScale = recognizer.scale
            if !twoFingerActive && recognizer.state == .began {
                twoFingerActive = true
                currentTranslation = .zero
                onStart()
            }
            if twoFingerActive {
                onChange(currentTranslation, currentScale)
            }
        }
        
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            return true
        }
    }
}
