import Foundation
import GameController

// MARK: - Input Event Handler
//
// Same shape as CloudNow's InputEventHandler protocol so VideoSurfaceView's
// keyboard/mouse capture code (HID → VK/scancode mapping) can be reused as-is.
protocol InputEventHandler: AnyObject {
    func sendKeyEvent(down: Bool, vk: UInt16, scancode: UInt16, modifiers: UInt16)
    func sendMouseMove(dx: Int16, dy: Int16)
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
    private let surfaceWidth: Int
    private let surfaceHeight: Int

    private var controllerPollTask: Task<Void, Never>?
    private var connectObserver: NSObjectProtocol?
    private var disconnectObserver: NSObjectProtocol?

    /// Radial deadzone applied to analog stick axes (0.0–1.0).
    var deadzone: Float = 0.15

    // Per-controller server-assigned ids (CONFIRMED required before the
    // server accepts button/axes/pad events for that controller — see
    // BoosteroidControlChannel's header comment) and the "name" token we
    // used to correlate the server's ack back to the right local controller.
    private var controllerIds: [ObjectIdentifier: String] = [:]
    private var pendingControllerNames: [ObjectIdentifier: String] = [:]

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
    }

    /// Fed by StreamController as it consumes BoosteroidControlChannel's
    /// incoming-event stream — see that file's header for why a single
    /// consumer owns the actor's AsyncStream.
    func handleIncoming(_ event: BoosteroidControlChannel.IncomingEvent) {
        switch event {
        case .controllerAck(let name, let id):
            if let key = pendingControllerNames.first(where: { $0.value == name })?.key {
                controllerIds[key] = id
                pendingControllerNames.removeValue(forKey: key)
            }
        case .webrtcEngineReady, .sessionActive, .controllerRumble, .raw, .closed, .failed:
            break // Not input events (StreamController handles engine-start /
                  // rumble not wired to a vibration API yet).
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

    private func pollGamepad(controller: GCController, id: String, pad: GCExtendedGamepad) {
        let key = ObjectIdentifier(controller)

        // Buttons 0-9 — CONFIRMED indices, see BoosteroidControlChannel.
        let buttons: [(Int, Bool)] = [
            (0, pad.buttonA.isPressed), (1, pad.buttonB.isPressed),
            (2, pad.buttonX.isPressed), (3, pad.buttonY.isPressed),
            (4, pad.leftShoulder.isPressed), (5, pad.rightShoulder.isPressed),
            (6, pad.buttonOptions?.isPressed ?? false), (7, pad.buttonMenu.isPressed),
            (8, pad.leftThumbstickButton?.isPressed ?? false),
            (9, pad.rightThumbstickButton?.isPressed ?? false),
        ]
        var buttonState = lastButtonState[key] ?? [:]
        for (index, isPressed) in buttons {
            if buttonState[index] != isPressed {
                buttonState[index] = isPressed
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
                Task { [controlChannel] in await controlChannel.send(type: "controller", action: "axes", fields: [
                    "id": id, "axes": index, "value": scaled,
                ]) }
            }
        }
        lastAxisState[key] = axisState

        // D-pad -> hat. TODO(protocol): only single-direction values are
        // reasonably inferable from the source; diagonals are approximated
        // with a standard 8-direction POV-hat numbering, not confirmed.
        let dpad = pad.dpad
        let hat: Int
        switch (dpad.up.isPressed, dpad.right.isPressed, dpad.down.isPressed, dpad.left.isPressed) {
        case (true, false, false, false): hat = 0   // up
        case (true, true, false, false):  hat = 1   // up-right
        case (false, true, false, false): hat = 2   // right
        case (false, true, true, false):  hat = 3   // down-right
        case (false, false, true, false): hat = 4   // down
        case (false, false, true, true):  hat = 5   // down-left
        case (false, false, false, true): hat = 6   // left
        case (true, false, false, true):  hat = 7   // up-left
        default: hat = -1 // neutral — not sent, matches "no dpad event" idle state
        }
        if lastHat[key] != hat {
            lastHat[key] = hat
            if hat >= 0 {
                Task { [controlChannel] in await controlChannel.send(type: "controller", action: "pad", fields: [
                    "id": id, "hat": hat,
                ]) }
            }
        }
    }

    private func applyDeadzone(_ value: Float) -> Float {
        abs(value) < deadzone ? 0 : value
    }
}
