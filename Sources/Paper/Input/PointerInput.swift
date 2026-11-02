import Foundation
import simd
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Pointer input normalised across mouse, trackpad, drawing tablet, Apple Pencil and touch.
public struct PointerEvent {
    public enum Phase { case began, moved, ended, cancelled, hover }
    public enum Device { case mouse, pen, touch }

    public var phase: Phase
    public var device: Device
    /// View coordinates in points (origin top-left).
    public var location: SIMD2<Float>
    /// Extra high-frequency samples since the last event (Pencil coalesced touches), oldest first.
    public var coalesced: [SIMD2<Float>] = []
    public var coalescedPressure: [Float] = []
    public var pressure: Float = 1
    /// Radians: π/2 upright, 0 flat.
    public var altitude: Float = .pi / 2
    /// Radians in view space.
    public var azimuth: Float = 0
    public var timestamp: TimeInterval
    /// Option / alt held (or a secondary click): temporary eyedropper.
    public var alternate = false
    public var shift = false
}

/// Gestures that move the canvas rather than paint on it.
public enum CanvasGesture {
    case pan(SIMD2<Float>)
    case zoom(factor: Float, around: SIMD2<Float>)
    case rotate(radians: Float, around: SIMD2<Float>)
    case undoTap, redoTap
}

@MainActor
public protocol PointerCaptureDelegate: AnyObject {
    func pointer(_ event: PointerEvent)
    func gesture(_ gesture: CanvasGesture)
    /// Return true if the key was handled.
    func key(_ stroke: KeyStroke, isDown: Bool) -> Bool
}

#if os(macOS)

/// Transparent NSView laid over the Metal canvas that turns AppKit events into `PointerEvent`s.
public final class PointerCaptureView: NSView {
    public weak var delegate: PointerCaptureDelegate?
    private var spaceDown = false
    private var panning = false
    private var lastPanPoint: SIMD2<Float>?

    public override var acceptsFirstResponder: Bool { true }
    public override var isFlipped: Bool { true }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
        window?.makeFirstResponder(self)
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow,
                                                               .inVisibleRect], owner: self))
    }

    private func point(_ e: NSEvent) -> SIMD2<Float> {
        let p = convert(e.locationInWindow, from: nil)
        return SIMD2(Float(p.x), Float(p.y))
    }

    private func make(_ phase: PointerEvent.Phase, _ e: NSEvent) -> PointerEvent {
        var ev = PointerEvent(phase: phase, device: .mouse, location: point(e), timestamp: e.timestamp)
        let isTablet = e.subtype == .tabletPoint || e.subtype == .tabletProximity
        if isTablet {
            ev.device = .pen
            ev.pressure = max(0.02, e.pressure)
            let tilt = SIMD2(Float(e.tilt.x), Float(-e.tilt.y))
            let lean = min(simd_length(tilt), 1)
            ev.altitude = (1 - lean) * .pi / 2
            ev.azimuth = lean > 0.01 ? atan2(tilt.y, tilt.x) : 0
        } else if phase == .moved || phase == .began {
            // Force Touch trackpads report pressure while clicking; plain mice report 1.
            ev.pressure = e.pressure > 0 ? max(0.05, e.pressure) : 1
        }
        ev.alternate = e.modifierFlags.contains(.option)
        ev.shift = e.modifierFlags.contains(.shift)
        return ev
    }

    public override func mouseDown(with e: NSEvent) {
        window?.makeFirstResponder(self)
        if spaceDown { panning = true; lastPanPoint = point(e); return }
        delegate?.pointer(make(.began, e))
    }

    public override func mouseDragged(with e: NSEvent) {
        if panning, let last = lastPanPoint {
            let p = point(e)
            delegate?.gesture(.pan(p - last))
            lastPanPoint = p
            return
        }
        delegate?.pointer(make(.moved, e))
    }

    public override func mouseUp(with e: NSEvent) {
        if panning { panning = false; lastPanPoint = nil; return }
        delegate?.pointer(make(.ended, e))
    }

    public override func rightMouseDown(with e: NSEvent) {
        var ev = make(.began, e)
        ev.alternate = true
        delegate?.pointer(ev)
        ev.phase = .ended
        delegate?.pointer(ev)
    }

    public override func otherMouseDragged(with e: NSEvent) {
        delegate?.gesture(.pan(SIMD2(Float(e.deltaX), Float(e.deltaY))))
    }

    public override func mouseMoved(with e: NSEvent) { delegate?.pointer(make(.hover, e)) }
    public override func tabletPoint(with e: NSEvent) { }

    public override func scrollWheel(with e: NSEvent) {
        if e.hasPreciseScrollingDeltas && !e.modifierFlags.contains(.command) {
            // Two-finger trackpad scroll pans, like Procreate on iPad.
            delegate?.gesture(.pan(SIMD2(Float(e.scrollingDeltaX), Float(e.scrollingDeltaY))))
        } else {
            let dy = Float(e.hasPreciseScrollingDeltas ? e.scrollingDeltaY * 0.01 : e.scrollingDeltaY * 0.1)
            delegate?.gesture(.zoom(factor: exp(dy), around: point(e)))
        }
    }

    public override func magnify(with e: NSEvent) {
        delegate?.gesture(.zoom(factor: Float(1 + e.magnification), around: point(e)))
    }

    public override func rotate(with e: NSEvent) {
        delegate?.gesture(.rotate(radians: -Float(e.rotation) * .pi / 180, around: point(e)))
    }

    private func keyStroke(_ e: NSEvent) -> KeyStroke {
        let f = e.modifierFlags
        let name: String
        switch e.keyCode {
        case 36, 76: name = "return"
        case 53: name = "escape"
        case 51: name = "delete"
        case 117: name = "delete"
        case 49: name = "space"
        case 48: name = "tab"
        default: name = (e.charactersIgnoringModifiers ?? "").lowercased()
        }
        return KeyStroke(name, command: f.contains(.command), shift: f.contains(.shift), option: f.contains(.option),
                         control: f.contains(.control))
    }

    public override func keyDown(with e: NSEvent) {
        if e.keyCode == 49 { spaceDown = true; NSCursor.openHand.set(); return }
        if delegate?.key(keyStroke(e), isDown: true) != true { super.keyDown(with: e) }
    }

    public override func keyUp(with e: NSEvent) {
        if e.keyCode == 49 { spaceDown = false; NSCursor.arrow.set(); return }
        _ = delegate?.key(keyStroke(e), isDown: false)
    }

    public override func performKeyEquivalent(with e: NSEvent) -> Bool {
        guard e.type == .keyDown, e.modifierFlags.contains(.command), window?.firstResponder === self else {
            return super.performKeyEquivalent(with: e)
        }
        return delegate?.key(keyStroke(e), isDown: true) == true || super.performKeyEquivalent(with: e)
    }
}

#else

/// UIView laid over the Metal canvas: Apple Pencil (pressure, tilt, coalesced + hover), touch gestures
/// (pinch/rotate/pan with two fingers, two-finger tap undo, three-finger tap redo) and hardware keyboards.
public final class PointerCaptureView: UIView, UIGestureRecognizerDelegate {
    public weak var delegate: PointerCaptureDelegate?
    /// When true (the default), only Apple Pencil paints; fingers navigate.
    public var pencilOnlyDrawing = true
    private var activeTouch: UITouch?
    private var lastPinchScale: CGFloat = 1
    private var lastRotation: CGFloat = 0
    private var lastPan: CGPoint = .zero

    public override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(onPinch(_:)))
        let rotate = UIRotationGestureRecognizer(target: self, action: #selector(onRotate(_:)))
        let pan = UIPanGestureRecognizer(target: self, action: #selector(onPan(_:)))
        pan.minimumNumberOfTouches = 2
        let undo = UITapGestureRecognizer(target: self, action: #selector(onUndoTap))
        undo.numberOfTouchesRequired = 2
        let redo = UITapGestureRecognizer(target: self, action: #selector(onRedoTap))
        redo.numberOfTouchesRequired = 3
        for g in [pinch, rotate, pan, undo, redo] as [UIGestureRecognizer] {
            g.delegate = self
            g.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
            addGestureRecognizer(g)
        }
        let hover = UIHoverGestureRecognizer(target: self, action: #selector(onHover(_:)))
        addGestureRecognizer(hover)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var canBecomeFirstResponder: Bool { true }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        becomeFirstResponder()
    }

    public func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith o: UIGestureRecognizer) -> Bool {
        true
    }

    private func sample(_ t: UITouch, phase: PointerEvent.Phase, event: UIEvent?) -> PointerEvent {
        let p = t.preciseLocation(in: self)
        var ev = PointerEvent(phase: phase, device: t.type == .pencil ? .pen : .touch,
                              location: SIMD2(Float(p.x), Float(p.y)), timestamp: t.timestamp)
        if t.type == .pencil {
            ev.pressure = t.maximumPossibleForce > 0 ? Float(max(0.02, t.force / t.maximumPossibleForce)) : 1
            ev.altitude = Float(t.altitudeAngle)
            ev.azimuth = Float(t.azimuthAngle(in: self))
        }
        if let coalesced = event?.coalescedTouches(for: t), coalesced.count > 1 {
            ev.coalesced = coalesced.dropLast().map { c in
                let q = c.preciseLocation(in: self)
                return SIMD2(Float(q.x), Float(q.y))
            }
            ev.coalescedPressure = coalesced.dropLast().map { c in
                c.maximumPossibleForce > 0 ? Float(max(0.02, c.force / c.maximumPossibleForce)) : 1
            }
        }
        return ev
    }

    private func canDraw(_ t: UITouch) -> Bool { !pencilOnlyDrawing || t.type == .pencil }

    public override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard activeTouch == nil, let t = touches.first(where: canDraw), (event?.allTouches?.count ?? 1) == 1 || t.type == .pencil
        else { return }
        activeTouch = t
        delegate?.pointer(sample(t, phase: .began, event: event))
    }

    public override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = activeTouch, touches.contains(t) else { return }
        delegate?.pointer(sample(t, phase: .moved, event: event))
    }

    public override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = activeTouch, touches.contains(t) else { return }
        delegate?.pointer(sample(t, phase: .ended, event: event))
        activeTouch = nil
    }

    public override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = activeTouch, touches.contains(t) else { return }
        delegate?.pointer(sample(t, phase: .cancelled, event: event))
        activeTouch = nil
    }

    @objc private func onHover(_ g: UIHoverGestureRecognizer) {
        let p = g.location(in: self)
        var ev = PointerEvent(phase: .hover, device: .pen, location: SIMD2(Float(p.x), Float(p.y)),
                              timestamp: ProcessInfo.processInfo.systemUptime)
        if #available(iOS 16.4, *) {
            ev.altitude = Float(g.altitudeAngle)
            ev.azimuth = Float(g.azimuthAngle(in: self))
        }
        delegate?.pointer(ev)
    }

    @objc private func onPinch(_ g: UIPinchGestureRecognizer) {
        if g.state == .began { lastPinchScale = 1 }
        let p = g.location(in: self)
        delegate?.gesture(.zoom(factor: Float(g.scale / lastPinchScale), around: SIMD2(Float(p.x), Float(p.y))))
        lastPinchScale = g.scale
    }

    @objc private func onRotate(_ g: UIRotationGestureRecognizer) {
        if g.state == .began { lastRotation = 0 }
        let p = g.location(in: self)
        delegate?.gesture(.rotate(radians: Float(g.rotation - lastRotation), around: SIMD2(Float(p.x), Float(p.y))))
        lastRotation = g.rotation
    }

    @objc private func onPan(_ g: UIPanGestureRecognizer) {
        let t = g.translation(in: self)
        if g.state == .began { lastPan = .zero }
        delegate?.gesture(.pan(SIMD2(Float(t.x - lastPan.x), Float(t.y - lastPan.y))))
        lastPan = t
    }

    @objc private func onUndoTap() { delegate?.gesture(.undoTap) }
    @objc private func onRedoTap() { delegate?.gesture(.redoTap) }

    public override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for press in presses {
            guard let key = press.key else { continue }
            let name: String
            switch key.keyCode {
            case .keyboardReturnOrEnter: name = "return"
            case .keyboardEscape: name = "escape"
            case .keyboardDeleteOrBackspace: name = "delete"
            case .keyboardSpacebar: name = "space"
            default: name = key.charactersIgnoringModifiers.lowercased()
            }
            let f = key.modifierFlags
            let stroke = KeyStroke(name, command: f.contains(.command), shift: f.contains(.shift),
                                   option: f.contains(.alternate), control: f.contains(.control))
            if delegate?.key(stroke, isDown: true) == true { handled = true }
        }
        if !handled { super.pressesBegan(presses, with: event) }
    }
}

#endif
