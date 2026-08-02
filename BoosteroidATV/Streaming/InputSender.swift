import CoreHaptics
import Foundation
import GameController

// MARK: - Input Event Handler
//
// Same shape as CloudNow's InputEventHandler protocol so VideoSurfaceView's
// keyboard/mouse capture code (HID → VK/scancode mapping) can be reused as-is.
protocol InputEventHandler: AnyObject {
    func sendKeyEvent(down: Bool, vk: UInt16, scancode: UInt16, modifiers: UInt16)
    func sendMouseMove(dx: Int16, dy: Int16)
    /// Absolute pointer position, in the streamed surface's pixels.
    func sendMouseAbsolute(x: Int, y: Int)
    func sendMouseButton(down: Bool, button: UInt8)
    func sendMouseWheel(delta: Int16)
}

// MARK: - Input Sender
//
// CONFIRMED 2026-07-23: this used to be a pure no-op stub built against the
// wrong transport entirely (a WebRTC data channel, carried over from
// CloudNow/GFN) — worse, StreamController never even instantiated it, so
// literally nothing was wired up. Live testing plus reading Boosteroid's own
// streaming.js/catch-events.js bundles found the real mechanism: a single
// dedicated JSON WebSocket (BoosteroidControlChannel) carries ALL input —
// keyboard, mouse, and gamepad. See that file's header comment for the full
// confirmed protocol (message shapes, button/axis indices, etc.) — this file
// just builds the field dictionaries it documents and encodes local
// GCController/keyboard/mouse state into them.
@MainActor
final class InputSender: InputEventHandler {
    private let controlChannel: BoosteroidControlChannel
    /// The surface size used to turn absolute pointer pixels into the
    /// fraction (0.0-1.0) the server expects (see sendMouseAbsolute). Starts
    /// at the REQUESTED resolution (StreamSettings), but that's only a guess
    /// until the first decoded frame reports the ACTUAL negotiated size —
    /// updateSurfaceSize(width:height:) keeps this in step with that, and
    /// with the same live value StreamView/VideoSurfaceView use for drawing
    /// and clamping (controller.stats.resolutionWidth/Height). Letting these
    /// drift apart (frozen requested size here vs. live actual size there)
    /// silently scales every absolute click: the drawn arrow tracks correctly
    /// but the coordinate actually sent lands somewhere else — confirmed
    /// 2026-07-27 as the cause of "arrow is right, click still does nothing"
    /// once the visual safe-area bug was fixed and the mismatch was no longer
    /// masked by it.
    private var surfaceWidth: Int
    private var surfaceHeight: Int

    private var controllerPollTask: Task<Void, Never>?
    private var connectObserver: NSObjectProtocol?
    private var disconnectObserver: NSObjectProtocol?

    /// Radial deadzone applied to analog stick axes (0.0–1.0).
    var deadzone: Float = 0.15

    // MARK: - Diagnostics (read by StreamController for the on-screen HUD)
    /// Number of extended gamepads currently seen by GameController.
    private(set) var connectedControllerCount = 0
    /// Total controller button/axes/pad frames sent since start().
    private(set) var controllerEventsSent = 0
    /// The most recent server-assigned controller id, if the ack arrived.
    /// nil means we're running on the provisional (index) id — input still
    /// flows, this just tells us whether the server handshake completed.
    private(set) var lastServerAckId: String?
    /// DIAGNOSTIC ONLY (added 2026-08-09): counts every time GameController's
    /// OWN buttonMenu.valueChangedHandler fires, completely independent of
    /// both pollGamepad's read of buttonMenu.isPressed AND
    /// VideoSurfaceView's pressesBegan/.menu UIPress handling. Two guesses
    /// about whether/how this button reaches us in a row have turned out
    /// wrong on real hardware (b509aef, then its revert) — this exists so
    /// the NEXT attempt is based on what actually happens on a real device
    /// instead of a third guess. Surfaced in the Performance Overlay as
    /// "MenuBtn". If this stays at 0 no matter how many times Start/Select
    /// is pressed, GameController's handler-based API for this button is
    /// genuinely dead in this input mode, full stop — no amount of
    /// poll-vs-UIPress rearranging will fix it, and the only way to reach
    /// the game from that button might be entirely UIPress-driven (which
    /// still failed once already — see b509aef's revert — so THAT would
    /// need its own real bug fix, not just resurrecting it as-is).
    private(set) var menuButtonHandlerFireCount = 0
    private(set) var menuButtonHandlerLastPressed = false
    /// DIAGNOSTIC ONLY: what pollGamepad's OWN read of button 7 actually saw,
    /// each tick, for whichever controller polled last — lets us tell apart
    /// "the send pipeline never even tries" (this stays 0) from "it sends,
    /// but something after that drops it" (this moves in lockstep with
    /// menuButtonHandlerFireCount above, which is driven by a totally
    /// separate GameController API).
    private(set) var menuButtonPollSendCount = 0
    /// DIAGNOSTIC ONLY: `controller.microGamepad != nil` as read by
    /// pollGamepad for whichever controller polled last — if this is
    /// unexpectedly `true` for a REAL controller, that alone would explain
    /// button 7 never being sent (isSiriRemote forces it to `false`
    /// regardless of the actual press).
    private(set) var lastPolledControllerIsSiriRemote = false

    // Per-controller server-assigned ids (CONFIRMED required before the
    // server accepts button/axes/pad events for that controller — see
    // BoosteroidControlChannel's header comment) and the "name" token we
    // used to correlate the server's ack back to the right local controller.
    // CONFIRMED 2026-07-24 against Boosteroid's live catch-events.js: the
    // gamepad `id` is a NUMBER on the wire (the client does Number(...) on it
    // and sends `{..., "id": <number>}`). Sending it as a JSON string — as an
    // earlier pass did — makes the server fail to match input frames to the
    // registered controller and silently drop ALL of them (the socket still
    // acks the connect, so it looks like it's working). Keyed as Int here so
    // every outgoing frame serializes `id` as a number.
    private var controllerIds: [ObjectIdentifier: Int] = [:]
    private var pendingControllerNames: [ObjectIdentifier: String] = [:]
    /// One CoreHaptics rig per controller that's actually rumbled at least
    /// once — see applyRumble's doc comment for why this is lazy and
    /// per-controller rather than set up at connect time.
    private var hapticsByController: [ObjectIdentifier: ControllerHaptics] = [:]

    // Change-detection state, mirroring the real web client's diffing (only
    // send an event when something actually changed) rather than flooding
    // the socket every poll tick.
    private var lastButtonState: [ObjectIdentifier: [Int: Bool]] = [:]
    private var lastAxisState: [ObjectIdentifier: [Int: Int]] = [:]
    private var lastHat: [ObjectIdentifier: Int] = [:]

    /// Same threshold the real web client uses (`GamepadController.
    /// AXIS_THRESHOLD`) before re-sending an axis value, out of a ±32767
    /// range — avoids flooding the socket with sub-pixel stick jitter.
    private static let axisChangeThreshold = 1200
    private static let maxAxis: Double = 32767

    init(controlChannel: BoosteroidControlChannel, surfaceWidth: Int, surfaceHeight: Int) {
        self.controlChannel = controlChannel
        self.surfaceWidth = surfaceWidth
        self.surfaceHeight = surfaceHeight
    }

    /// Called by StreamController's stats loop once the decoded frame size is
    /// known, so absolute-pointer fractions are computed against the REAL
    /// negotiated resolution rather than whatever was merely requested.
    func updateSurfaceSize(width: Int, height: Int) {
        guard width > 0, height > 0 else { return }
        surfaceWidth = width
        surfaceHeight = height
    }

    func start() {
        // CONFIRMED handshake: the web client sends this once before any
        // mouse button/move events.
        Task { [controlChannel] in await controlChannel.send(type: "mouse", action: "connected", fields: [
            "LeftBtnState": false, "MiddleBtnState": false, "RightBtnState": false,
        ]) }

        // queue: .main means these fire on the main thread, so hop to the main
        // actor synchronously (assumeIsolated) instead of spawning a Task that
        // captures self concurrently.
        connectObserver = NotificationCenter.default.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] note in
            guard let controller = note.object as? GCController else { return }
            MainActor.assumeIsolated { self?.handleControllerConnected(controller) }
        }
        disconnectObserver = NotificationCenter.default.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] note in
            guard let controller = note.object as? GCController else { return }
            MainActor.assumeIsolated { self?.handleControllerDisconnected(controller) }
        }
        for controller in GCController.controllers() {
            handleControllerConnected(controller)
        }

        observeControllers()
    }

    func stop() {
        controllerPollTask?.cancel()
        controllerPollTask = nil
        if let connectObserver { NotificationCenter.default.removeObserver(connectObserver) }
        if let disconnectObserver { NotificationCenter.default.removeObserver(disconnectObserver) }
        connectObserver = nil
        disconnectObserver = nil
        for haptics in hapticsByController.values { haptics.stop() }
        hapticsByController.removeAll()
    }

    /// Fed by StreamController as it consumes BoosteroidControlChannel's
    /// incoming-event stream — see that file's header for why a single
    /// consumer owns the actor's AsyncStream.
    func handleIncoming(_ event: BoosteroidControlChannel.IncomingEvent) {
        switch event {
        case .controllerAck(let name, let id):
            lastServerAckId = id
            if let key = pendingControllerNames.first(where: { $0.value == name })?.key {
                // Upgrade from the provisional (index) id to the server's id.
                // The server sends it as a number; keep the provisional index
                // if it somehow isn't parseable as one.
                controllerIds[key] = Int(id) ?? controllerIds[key]
                pendingControllerNames.removeValue(forKey: key)
            }
        case .controllerRumble(let id, let left, let right):
            applyRumble(id: id, left: left, right: right)
        case .webrtcEngineReady, .sessionActive, .cursor, .raw, .closed, .failed:
            break // Not input events — StreamController handles engine-start.
        }
    }

    // MARK: - Keyboard

    func sendKeyEvent(down: Bool, vk: UInt16, scancode: UInt16, modifiers: UInt16) {
        Task { [controlChannel] in await controlChannel.send(type: "keyboard", action: "button", fields: [
            "isPressed": down, "code": Int(vk),
        ]) }
    }

    // MARK: - Mouse

    func sendMouseMove(dx: Int16, dy: Int16) {
        // CONFIRMED relative-move shape (see BoosteroidControlChannel) — the
        // real client also supports absolute/locked-cursor modes with a lot
        // of adaptive normalization, not ported here (see that file's TODO).
        let width = surfaceWidth, height = surfaceHeight
        Task { [controlChannel] in await controlChannel.send(type: "mouse", fields: [
            "movementX": Int(dx), "movementY": Int(dy),
            "surfaceWidth": width, "surfaceHeight": height,
            "syncLocalPosition": false, "movementIsAdjusted": true,
        ]) }
    }

    /// CONFIRMED 2026-07-27 by live-capturing the REAL WebSocket frames the web
    /// client sends (patched `WebSocket.prototype.send` and watched a live
    /// session, rather than reading source and guessing at field names). The
    /// previous "confirmed" shape — `{type:"mouse", X, Y, surfaceWidth,
    /// surfaceHeight}` — was still wrong: the server silently ignored it
    /// because it's missing `action`, and `X`/`Y` are NOT pixels.
    ///
    /// The real message, captured clicking around the Steam desktop:
    ///   {type:"mouse", action:"move", X, Y, offsetX:0, offsetY:0,
    ///    isVisible:true}
    ///
    /// `X`/`Y` are FRACTIONS of the surface (0.0–1.0), not pixel coordinates —
    /// e.g. `X:0.545` for a click near the middle of the screen. There is no
    /// `surfaceWidth`/`surfaceHeight` in this message at all (those only
    /// appear on the relative-move shape in `sendMouseMove`). `offsetX`/
    /// `offsetY` were always 0 in the capture; `isVisible` was always true.
    /// This finally explains "the arrow moves but clicking does nothing": our
    /// button down/up was reaching the server fine, but the server had no idea
    /// where the cursor was because every move message before it was shaped
    /// wrong and silently dropped.
    func sendMouseAbsolute(x: Int, y: Int) {
        let fx = surfaceWidth > 0 ? min(max(Double(x) / Double(surfaceWidth), 0), 1) : 0
        let fy = surfaceHeight > 0 ? min(max(Double(y) / Double(surfaceHeight), 0), 1) : 0
        Task { [controlChannel] in await controlChannel.send(type: "mouse", action: "move", fields: [
            "X": fx, "Y": fy,
            "offsetX": 0, "offsetY": 0,
            "isVisible": true,
        ]) }
    }

    func sendMouseButton(down: Bool, button: UInt8) {
        Task { [controlChannel] in await controlChannel.send(type: "mouse", action: "button", fields: [
            "isPressed": down, "btn": Int(button),
        ]) }
    }

    func sendMouseWheel(delta: Int16) {
        Task { [controlChannel] in await controlChannel.send(type: "mouse", action: "wheel", fields: [
            "deltaY": delta > 0 ? 1 : -1,
        ]) }
    }

    // MARK: - Controller Connect / Disconnect

    private func handleControllerConnected(_ controller: GCController) {
        let key = ObjectIdentifier(controller)
        guard controllerIds[key] == nil, pendingControllerNames[key] == nil else { return }
        let index = GCController.controllers().firstIndex(of: controller) ?? 0
        // CONFIRMED shape: the browser sends `${gamepad.id}${gamepad.index}`
        // as a correlation token; any reasonably unique string works the
        // same way here since we only need it to match our own ack.
        let name = "\(controller.vendorName ?? "Boosteroid tvOS Controller")#\(index)"
        pendingControllerNames[key] = name

        // Provisional id so polling can send input IMMEDIATELY, without
        // deadlocking on a server ack that (per real-hardware testing) may
        // never arrive or arrive in an unparsed shape. We use the controller
        // index — the browser's Gamepad API keys events by gamepad.index, so
        // this is the most likely value the server assigns anyway. If a real
        // controller/connected ack does come back, handleIncoming upgrades
        // controllerIds[key] to the server's id (see there).
        controllerIds[key] = index
        connectedControllerCount = GCController.controllers().count

        // DIAGNOSTIC ONLY — see menuButtonHandlerFireCount's doc comment.
        // GCController's handlerQueue defaults to the main queue, but hop
        // explicitly anyway since that default is easy to get wrong; this
        // class is @MainActor and every other mutation assumes it.
        controller.extendedGamepad?.buttonMenu.valueChangedHandler = { [weak self] _, _, pressed in
            DispatchQueue.main.async {
                self?.menuButtonHandlerFireCount += 1
                self?.menuButtonHandlerLastPressed = pressed
            }
        }

        Task { [controlChannel] in await controlChannel.send(type: "controller", action: "connected", fields: ["name": name]) }
    }

    private func handleControllerDisconnected(_ controller: GCController) {
        let key = ObjectIdentifier(controller)
        if let id = controllerIds[key] {
            Task { [controlChannel] in await controlChannel.send(type: "controller", action: "disconnected", fields: ["id": id]) }
        }
        controllerIds.removeValue(forKey: key)
        pendingControllerNames.removeValue(forKey: key)
        lastButtonState.removeValue(forKey: key)
        lastAxisState.removeValue(forKey: key)
        lastHat.removeValue(forKey: key)
        if let haptics = hapticsByController.removeValue(forKey: key) { haptics.stop() }
        connectedControllerCount = GCController.controllers().count
    }

    // MARK: - Controller Polling
    //
    // CONFIRMED button/axis indices — see BoosteroidControlChannel's header.
    // D-pad hat encoding is the one unconfirmed piece (documented there).

    private func observeControllers() {
        controllerPollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                for controller in GCController.controllers() {
                    guard let pad = controller.extendedGamepad,
                          let id = self.controllerIds[ObjectIdentifier(controller)] else { continue }
                    self.pollGamepad(controller: controller, id: id, pad: pad)
                }
                try? await Task.sleep(nanoseconds: 16_000_000) // ~60Hz poll
            }
        }
    }

    private func pollGamepad(controller: GCController, id: Int, pad: GCExtendedGamepad) {
        let key = ObjectIdentifier(controller)

        // The Siri Remote reports only a microGamepad profile — GameController
        // synthesizes an extendedGamepad on top of it purely so apps that only
        // handle extendedGamepad still work, which is why `pad` (and its
        // buttonMenu) is non-nil for it too.
        let isSiriRemote = controller.microGamepad != nil
        lastPolledControllerIsSiriRemote = isSiriRemote

        // Buttons 0-9 — CONFIRMED indices, see BoosteroidControlChannel.
        let buttons: [(Int, Bool)] = [
            (0, pad.buttonA.isPressed), (1, pad.buttonB.isPressed),
            (2, pad.buttonX.isPressed), (3, pad.buttonY.isPressed),
            (4, pad.leftShoulder.isPressed), (5, pad.rightShoulder.isPressed),
            (6, pad.buttonOptions?.isPressed ?? false),
            // CONFIRMED on a real device (2026-08-09, via the MenuBtn/
            // PollSend/SiriRemote diagnostics added for exactly this):
            // pressing Start on a REAL gamepad reported SiriRemote = true
            // and PollSend never moved — i.e. tvOS funnels a real
            // controller's own Menu/Start button through the SAME unified
            // system channel as the Siri Remote's own Back/"<" button
            // (GCController.microGamepad != nil on whichever object the OS
            // delivers it through), not through that controller's own
            // extendedGamepad profile. This is a hard platform limitation,
            // not a bug we can route around: there is NO reliable way, via
            // GameController polling, valueChangedHandler, or UIPress +
            // GCController.current, to tell "the Remote's own Back button"
            // apart from "a real gamepad's Start button" — the OS discards
            // that distinction before any of these APIs see it. Asked the
            // user to pick a priority given that hard constraint: they chose
            // Start reaching the game over Back auto-dismissing to Home
            // (see VideoSurfaceView.pressesBegan, which now swallows EVERY
            // Menu press instead of only real controllers'). So button 7 is
            // now sent unconditionally — accepting that the Remote's own
            // Back button will also send a Start press to the game.
            (7, pad.buttonMenu.isPressed),
            (8, pad.leftThumbstickButton?.isPressed ?? false),
            (9, pad.rightThumbstickButton?.isPressed ?? false),
        ]
        var buttonState = lastButtonState[key] ?? [:]
        for (index, isPressed) in buttons {
            if buttonState[index] != isPressed {
                buttonState[index] = isPressed
                controllerEventsSent += 1
                if index == 7 { menuButtonPollSendCount += 1 } // DIAGNOSTIC ONLY
                Task { [controlChannel] in await controlChannel.send(type: "controller", action: "button", fields: [
                    "id": id, "button": index, "value": isPressed ? 1 : 0,
                ]) }
            }
        }
        lastButtonState[key] = buttonState

        // Axes 0-5 — CONFIRMED indices/range, see BoosteroidControlChannel.
        // GameController's Y axis is +1-up; the browser Gamepad API (and
        // therefore Boosteroid's protocol) uses +1-down — flipped here.
        let axes: [(Int, Float)] = [
            (0, applyDeadzone(pad.leftThumbstick.xAxis.value)),
            (1, applyDeadzone(-pad.leftThumbstick.yAxis.value)),
            (2, pad.leftTrigger.value),
            (3, applyDeadzone(pad.rightThumbstick.xAxis.value)),
            (4, applyDeadzone(-pad.rightThumbstick.yAxis.value)),
            (5, pad.rightTrigger.value),
        ]
        var axisState = lastAxisState[key] ?? [:]
        for (index, value) in axes {
            let scaled: Int
            if index == 2 || index == 5 {
                // Triggers: [0,1] linearly remapped onto the same ±32767
                // range as sticks — CONFIRMED formula, see
                // BoosteroidControlChannel.
                scaled = Int((Double(value) * Self.maxAxis * 2).rounded()) - Int(Self.maxAxis)
            } else {
                scaled = Int((Double(value) * Self.maxAxis).rounded())
            }
            let old = axisState[index] ?? (index == 2 || index == 5 ? -Int(Self.maxAxis) : 0)
            if abs(scaled - old) > Self.axisChangeThreshold {
                axisState[index] = scaled
                controllerEventsSent += 1
                Task { [controlChannel] in await controlChannel.send(type: "controller", action: "axes", fields: [
                    "id": id, "axes": index, "value": scaled,
                ]) }
            }
        }
        lastAxisState[key] = axisState

        // D-pad -> hat. CONFIRMED 2026-07-24 against Boosteroid's live
        // catch-events.js: the `hat` is a DIRECTION BITMASK, not a POV-hat
        // rotation number — up=1, right=2, down=4, left=8, OR'd together for
        // diagonals (up+left=9, up+right=3, down+left=12, down+right=6). And
        // crucially the client sends hat=0 on release; without that the server
        // treats the last direction as still held (this was the "d-pad press
        // repeats / sticks" bug). An earlier pass used a 0–7 POV numbering
        // where our "up" was 0 — which the server reads as neutral, so up
        // silently did nothing.
        let dpad = pad.dpad
        var hat = 0
        if dpad.up.isPressed    { hat |= 1 }
        if dpad.right.isPressed { hat |= 2 }
        if dpad.down.isPressed  { hat |= 4 }
        if dpad.left.isPressed  { hat |= 8 }
        if lastHat[key] != hat {
            lastHat[key] = hat
            controllerEventsSent += 1
            // Sent on every change INCLUDING back to 0, so releases register.
            Task { [controlChannel] in await controlChannel.send(type: "controller", action: "pad", fields: [
                "id": id, "hat": hat,
            ]) }
        }
    }

    private func applyDeadzone(_ value: Float) -> Float {
        abs(value) < deadzone ? 0 : value
    }

    // MARK: - Controller Rumble
    //
    // CONFIRMED (see BoosteroidControlChannel's header): the server pushes
    // {"type":"controller","action":"rumble", id, left, right} whenever the
    // streamed game rumbles the gamepad, `left`/`right` each 0...1. Real
    // vibration on tvOS ONLY comes through GameController's CoreHaptics
    // bridge (GCController.haptics) — there's no simple "set rumble" call.
    // CHHapticEngine has real per-event startup latency, far too slow to
    // build and play a brand-new pattern for every rumble update (these can
    // arrive many times a second while a game rumbles continuously), so
    // instead one looping CHHapticContinuous player per motor is created
    // ONCE per controller and its intensity is nudged live via
    // sendParameters — the same technique Apple's own GameController haptics
    // sample code uses for continuous, variable-intensity feedback.

    /// One CoreHaptics engine + looping player pinned to a single haptics
    /// locality (e.g. the left or right rumble motor).
    private struct HapticChannel {
        let engine: CHHapticEngine
        let player: CHHapticAdvancedPatternPlayer

        func setIntensity(_ value: Double) {
            let clamped = Float(min(max(value, 0), 1))
            let param = CHHapticDynamicParameter(parameterID: .hapticIntensityControl, value: clamped, relativeTime: 0)
            try? player.sendParameters([param], atTime: CHHapticTimeImmediate)
        }

        func stop() {
            try? player.stop(atTime: CHHapticTimeImmediate)
            engine.stop()
        }
    }

    /// Either a genuinely separate left/right pair (controllers like
    /// DualSense/DualShock that report distinct rumble motor localities) or
    /// one shared channel driven by max(left, right) for controllers that
    /// only expose a single, undifferentiated rumble motor (most Xbox-style
    /// pads via GameController's `.default` locality).
    private struct ControllerHaptics {
        var left: HapticChannel?
        var right: HapticChannel?
        var combined: HapticChannel?

        func update(left leftValue: Double, right rightValue: Double) {
            if left != nil || right != nil {
                left?.setIntensity(leftValue)
                right?.setIntensity(rightValue)
            } else {
                combined?.setIntensity(max(leftValue, rightValue))
            }
        }

        func stop() {
            left?.stop()
            right?.stop()
            combined?.stop()
        }
    }

    /// Server -> client rumble handler. Looks the wire `id` back up to the
    /// real GCController (via the same controllerIds map outgoing input
    /// uses), then lazily builds this controller's haptics rig on the FIRST
    /// nonzero rumble rather than at connect time — most sessions never
    /// rumble at all, and CHHapticEngine has real overhead not worth paying
    /// up front for every connected controller.
    private func applyRumble(id: String, left: Double, right: Double) {
        guard let targetId = Int(id),
              let key = controllerIds.first(where: { $0.value == targetId })?.key,
              let controller = GCController.controllers().first(where: { ObjectIdentifier($0) == key }),
              let haptics = controller.haptics
        else { return }

        if let existing = hapticsByController[key] {
            existing.update(left: left, right: right)
            return
        }
        guard left > 0 || right > 0,
              let created = Self.makeControllerHaptics(haptics: haptics)
        else { return }
        hapticsByController[key] = created
        created.update(left: left, right: right)
    }

    /// Prefers distinct left/right motor channels when the controller
    /// reports both localities (CONFIRMED available on DualSense/DualShock
    /// via GCDeviceHaptics.supportedLocalities); otherwise falls back to one
    /// shared `.default` channel.
    private static func makeControllerHaptics(haptics: GCDeviceHaptics) -> ControllerHaptics? {
        let supported = haptics.supportedLocalities
        if supported.contains(.leftHandle), supported.contains(.rightHandle) {
            let left = makeChannel(haptics: haptics, locality: .leftHandle)
            let right = makeChannel(haptics: haptics, locality: .rightHandle)
            guard left != nil || right != nil else { return nil }
            return ControllerHaptics(left: left, right: right, combined: nil)
        }
        guard let combined = makeChannel(haptics: haptics, locality: .default) else { return nil }
        return ControllerHaptics(left: nil, right: nil, combined: combined)
    }

    /// One engine + a 1-second continuous event looped forever (`loopEnabled`)
    /// starting at zero intensity — intensity is then driven entirely via
    /// HapticChannel.setIntensity's live sendParameters calls, so this
    /// initial pattern is just a "holder" the loop plays, never heard at its
    /// own 0-intensity value.
    private static func makeChannel(haptics: GCDeviceHaptics, locality: GCHapticsLocality) -> HapticChannel? {
        guard let engine = haptics.createEngine(withLocality: locality) else { return nil }
        do {
            try engine.start()
            let event = CHHapticEvent(
                eventType: .hapticContinuous,
                parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: 0),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.5),
                ],
                relativeTime: 0,
                duration: 1
            )
            let pattern = try CHHapticPattern(events: [event], parameters: [])
            let player = try engine.makeAdvancedPlayer(with: pattern)
            player.loopEnabled = true
            player.loopEnd = 1
            try player.start(atTime: CHHapticTimeImmediate)
            return HapticChannel(engine: engine, player: player)
        } catch {
            return nil
        }
    }
}
