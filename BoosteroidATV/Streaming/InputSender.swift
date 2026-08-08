import CoreHaptics
import Foundation
import GameController

extension Notification.Name {
    /// Posted (main thread) on the rising edge of Start + Select being held
    /// together on a gamepad — see InputSender.pollGamepad for why a combo is
    /// needed at all. StreamView listens for this to open the options bar.
    static let gamepadPauseComboPressed = Notification.Name("BoosteroidATV.gamepadPauseComboPressed")
}

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
    /// DIAGNOSTIC (added 2026-08-09): total `{"type":"controller","action":
    /// "rumble",...}` messages received from the server this session. If
    /// this stays at 0 no matter what happens in-game, the server simply
    /// never sent a rumble event for this game/session — nothing on this
    /// client's end could fix that, since applyRumble is never even called.
    private(set) var rumbleMessagesReceived = 0
    private(set) var rumbleLastLeft: Double = 0
    private(set) var rumbleLastRight: Double = 0
    /// DIAGNOSTIC: nil until the first nonzero rumble is actually attempted
    /// (see applyRumble — haptics setup is lazy). Once set: `false` means
    /// `GCController.haptics` was nil for this controller, i.e. GameController
    /// reports it doesn't support haptics on this device at all — no amount
    /// of CoreHaptics code here can fix that; `true` means haptics setup was
    /// attempted (see rumbleSetupError for whether it actually succeeded).
    private(set) var rumbleHapticsAvailable: Bool?
    /// DIAGNOSTIC: set if CHHapticEngine/pattern/player setup threw, so a
    /// silent failure (the old code just returned nil) is visible instead of
    /// looking identical to "never tried".
    private(set) var rumbleSetupError: String?
    /// DIAGNOSTIC (added 2026-08-09, round 2 — setup now succeeds with no
    /// error but nothing physically vibrates): `GCDeviceHaptics.
    /// supportedLocalities` for whichever controller last rumbled, captured
    /// at setup time. Rules in/out "we're playing on a locality this
    /// specific controller doesn't actually back with a real motor" — e.g.
    /// if this never contains `.default`, engine.createEngine(withLocality:
    /// .default) may have silently created a channel that plays into
    /// nothing.
    private(set) var rumbleSupportedLocalities: String = "-"
    /// DIAGNOSTIC (added 2026-08-09, round 3 — Haptics: yes, Localities set,
    /// RumbleLR shows real nonzero values arriving, still nothing physically
    /// vibrates): the old code drove intensity purely through
    /// `player.sendParameters` wrapped in `try?`, so if that dynamic
    /// parameter update silently failed or no-op'd against a
    /// GCController-backed engine — plausible, since we already hit one
    /// undocumented Apple gap in this exact API surface with the Advanced
    /// player — we'd never know. Now surfaced here; see HapticChannel for
    /// the actual fix (rebuild the pattern with the intensity baked in
    /// statically instead of relying on live parameter modulation).
    private(set) var rumbleSendError: String?
    /// User-configurable overall rumble toggle + intensity (Settings >
    /// Controller > Rumble / Rumble intensity), set once by StreamController.
    /// connect from the active StreamSettings. Applied on top of whatever
    /// left/right the server sends, right before the value reaches
    /// CoreHaptics — rumbleLastLeft/rumbleLastRight above still reflect the
    /// RAW server values regardless of this, so they stay useful for
    /// debugging "is the server actually sending rumble" independent of the
    /// user's own intensity preference.
    var rumbleEnabled: Bool = true
    var rumbleIntensityMultiplier: Double = 1.0

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
    /// Rising-edge tracking for the Start+Select options-bar combo. Separate
    /// from lastButtonState because the combo is handled locally and must not
    /// interfere with the individual button events still sent to the game.
    private var lastPauseComboState: [ObjectIdentifier: Bool] = [:]

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
            rumbleMessagesReceived += 1
            rumbleLastLeft = left
            rumbleLastRight = right
            applyRumble(id: id, left: left, right: right)
        case .webrtcEngineReady, .sessionActive, .cursor, .raw, .closed, .failed:
            break // Not input events — StreamController handles engine-start.
        }
    }

    /// Re-sends `controller/connected` for every gamepad the server has NOT
    /// acked yet. Called by StreamController the moment video actually starts
    /// (see its state = .streaming transition).
    ///
    /// Fixes the reported "the FIRST session never picks up the controller —
    /// I have to leave to Home and reopen the game for it to work". Root
    /// cause: `start()` announces controllers as soon as
    /// `controlChannel.connect()` returns, but that returns immediately (it
    /// just flips `isOpen` and resumes the URLSessionWebSocketTask) — long
    /// before the server has finished bringing the session up and created the
    /// virtual gamepad on the Windows side. An announce that lands during
    /// that window is simply dropped server-side, and nothing ever retried
    /// it: `handleControllerConnected` optimistically records a provisional
    /// id locally and then permanently skips that controller on every later
    /// call (it guards on controllerIds/pendingControllerNames being empty),
    /// so the pad looked registered to us and didn't exist to the server for
    /// the rest of the session. Reopening the game worked because the second
    /// connect hits an already-warm session.
    ///
    /// Only unacked controllers are re-sent — `pendingControllerNames` is
    /// cleared in `handleIncoming` the moment an ack arrives — so a gamepad
    /// the server already knows about is never announced twice (which would
    /// risk registering a duplicate pad).
    func reannounceUnackedControllers() {
        for name in pendingControllerNames.values {
            Task { [controlChannel] in
                await controlChannel.send(type: "controller", action: "connected", fields: ["name": name])
            }
        }
    }

    // MARK: - Keyboard

    func sendKeyEvent(down: Bool, vk: UInt16, scancode: UInt16, modifiers: UInt16) {
        Task { [controlChannel] in await controlChannel.send(type: "keyboard", action: "button", fields: [
            "isPressed": down, "code": Int(vk),
        ]) }
    }

    /// Sends a multi-key combo (e.g. Shift+Tab for Steam's in-game overlay)
    /// as a single, strictly-ordered sequence: every key down (in order),
    /// held briefly, then every key up (in reverse order). Unlike calling
    /// `sendKeyEvent` once per key — each of which fires its own independent,
    /// unstructured `Task` — this awaits every `controlChannel.send` directly
    /// in ONE task, so the four WebSocket frames cannot arrive out of order.
    /// A modifier-then-key combo where the "up" for the modifier races ahead
    /// of (or ties with) the actual key press is exactly the kind of thing a
    /// remote low-level keyboard hook (which is what a Steam overlay hotkey
    /// is) can miss — the brief hold below also gives that hook a real
    /// window in which both keys are simultaneously down, rather than
    /// relying on four back-to-back frames landing in the same instant.
    func sendKeyCombo(_ vks: [UInt16]) {
        Task { [controlChannel] in
            for vk in vks {
                await controlChannel.send(type: "keyboard", action: "button", fields: [
                    "isPressed": true, "code": Int(vk),
                ])
            }
            try? await Task.sleep(nanoseconds: 60_000_000) // 60ms hold
            for vk in vks.reversed() {
                await controlChannel.send(type: "keyboard", action: "button", fields: [
                    "isPressed": false, "code": Int(vk),
                ])
            }
        }
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
        // EXTENDED GAMEPADS ONLY. Bug found 2026-08-06 from a decisive user
        // report: "picking up the Siri Remote made a controller show up as
        // connected in Steam, but using it does nothing." On tvOS the Siri
        // Remote is itself a GCController — it exposes a `microGamepad` but
        // NEVER an `extendedGamepad`, and it typically only appears in
        // GCController.controllers() once it's physically woken/used. This
        // function used to accept ANY GCController, so the Remote got
        // registered and announced to the server as a connected gamepad,
        // while the poll loop correctly skipped it for actual input (it
        // guards on extendedGamepad) — a phantom controller, exactly as
        // reported. It also shifted the REAL gamepad's index (see below).
        guard controller.extendedGamepad != nil else { return }

        let key = ObjectIdentifier(controller)
        guard controllerIds[key] == nil, pendingControllerNames[key] == nil else { return }

        // Index among EXTENDED GAMEPADS only, not all GCControllers. The
        // browser Gamepad API this mirrors never sees a Siri Remote, so
        // counting non-gamepad GCControllers here pushed the real gamepad to
        // index 1 (or higher) and made our provisional id disagree with the
        // id the server assigns — and the server keys every input frame by
        // that id, so mismatched input is silently dropped.
        let gamepads = GCController.controllers().filter { $0.extendedGamepad != nil }
        let index = gamepads.firstIndex(of: controller) ?? 0
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
        connectedControllerCount = gamepads.count

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
        lastPauseComboState.removeValue(forKey: key)
        if let haptics = hapticsByController.removeValue(forKey: key) { haptics.stop() }
        // Extended gamepads only, matching handleControllerConnected — this
        // count feeds the on-screen diagnostics, so counting the Siri Remote
        // made it read one higher than the number of real gamepads.
        connectedControllerCount = GCController.controllers().filter { $0.extendedGamepad != nil }.count
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
                    // Self-healing registration: `handleControllerConnected`
                    // is otherwise only ever called once up front (start()'s
                    // initial GCController.controllers() sweep) and from the
                    // .GCControllerDidConnect notification. Reported symptom:
                    // "sometimes leaving and re-entering a session, the
                    // controller doesn't connect" — GameController's own
                    // notification delivery is known to occasionally be late
                    // or missed entirely right after the app backgrounds/
                    // foregrounds or a Bluetooth controller re-pairs, and
                    // nothing was ever retried if that happened. Calling this
                    // every poll tick is safe/idempotent — it already guards
                    // on controllerIds/pendingControllerNames being empty for
                    // this controller — so a controller that's physically
                    // present but somehow never got registered self-heals
                    // within ~1 poll interval instead of staying dead for the
                    // rest of the session.
                    self.handleControllerConnected(controller)
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

        // Buttons 0-9 — CONFIRMED indices, see BoosteroidControlChannel.
        // Button 7 (Menu/Start): CONFIRMED 2026-08-09 on a real device that
        // tvOS funnels a real gamepad's own Menu/Start button through the
        // exact same unified system channel as the Siri Remote's own
        // Back/"<" button — there is no reliable way to tell them apart at
        // this layer (see VideoSurfaceView.pressesBegan's .menu handling for
        // the full story), so this is sent unconditionally: the Remote's own
        // Back button now also sends a Start press to the game, a deliberate
        // trade-off the user chose over Back auto-dismissing to Home.
        let buttons: [(Int, Bool)] = [
            (0, pad.buttonA.isPressed), (1, pad.buttonB.isPressed),
            (2, pad.buttonX.isPressed), (3, pad.buttonY.isPressed),
            (4, pad.leftShoulder.isPressed), (5, pad.rightShoulder.isPressed),
            (6, pad.buttonOptions?.isPressed ?? false),
            (7, pad.buttonMenu.isPressed),
            (8, pad.leftThumbstickButton?.isPressed ?? false),
            (9, pad.rightThumbstickButton?.isPressed ?? false),
        ]
        var buttonState = lastButtonState[key] ?? [:]
        for (index, isPressed) in buttons {
            if buttonState[index] != isPressed {
                buttonState[index] = isPressed
                controllerEventsSent += 1
                Task { [controlChannel] in await controlChannel.send(type: "controller", action: "button", fields: [
                    "id": id, "button": index, "value": isPressed ? 1 : 0,
                ]) }
            }
        }
        lastButtonState[key] = buttonState

        // Start + Select (Menu + Options) held together opens this app's own
        // options bar. A standard gamepad has NO Play/Pause button — that's a
        // Siri Remote button — while Menu/Start is deliberately forwarded to
        // the game (button 7 above) and Home is reserved by tvOS at the OS
        // level (confirmed on real hardware: it opens Control Center, the app
        // never sees it). So before this there was no way whatsoever to reach
        // the bar from a controller; the user could only do it from the Siri
        // Remote.
        //
        // This classic emulator-style combo costs the game nothing: both
        // buttons still pass through normally on their own (they're sent
        // unconditionally in the loop above either way), and pressing both at
        // once is hard to do by accident. Fires on the rising edge only, so
        // holding the combo doesn't toggle the bar repeatedly.
        let comboHeld = pad.buttonMenu.isPressed && (pad.buttonOptions?.isPressed ?? false)
        if comboHeld, !(lastPauseComboState[key] ?? false) {
            NotificationCenter.default.post(name: .gamepadPauseComboPressed, object: nil)
        }
        lastPauseComboState[key] = comboHeld

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

    /// One CoreHaptics engine + player pinned to a single haptics locality
    /// (e.g. the left or right rumble motor).
    ///
    /// CONFIRMED 2026-08-09 (real device: error "Sync XPC call for
    /// 'loadAndPrepareHapticSequenceFromEvents:reply:' ... Could not
    /// communicate with a helper application" / "connection to service ...
    /// com.apple.GameController.gamecontrollerd.haptics") — this is a KNOWN,
    /// still-unresolved Apple bug, not something wrong in this file:
    /// `CHHapticAdvancedPatternPlayer` (via `engine.makeAdvancedPlayer`)
    /// reliably fails this exact way against a GCController-provided haptics
    /// engine (see the Apple Developer Forums thread "CHHapticAdvancedPatternPlayer
    /// not working with GCController" — an Apple DTS engineer's only reply was
    /// "please file a bug", no fix). The PLAIN `CHHapticPatternPlayer` (via
    /// `engine.makePlayer`) works fine on the same engine in that same report,
    /// and that holds here too. The trade-off: the plain player has no
    /// `loopEnabled`/`loopEnd` (Advanced-only), so instead of a 1-second loop
    /// this uses one very long-duration continuous event (24h — more than any
    /// real streaming session) and drives it entirely via live
    /// sendParameters calls, same as before.
    /// FIX (round 3, 2026-08-09): this used to hold ONE long-running
    /// continuous player started at intensity 0, nudged live via
    /// `player.sendParameters([.hapticIntensityControl], ...)` wrapped in
    /// `try?`. On a real device that setup succeeds with no thrown error and
    /// rumble messages visibly arrive with real nonzero values (see
    /// InputSender's RumbleLR/Localities diagnostics) — yet nothing
    /// physically vibrates. Since `try?` swallowed any `sendParameters`
    /// failure, there was no way to tell "modulation silently no-ops against
    /// this GCController-backed engine" (which would exactly match the
    /// already-confirmed Advanced-player XPC bug's flavor of "the API
    /// accepts the call and does nothing") from "it's working and something
    /// else is wrong". Rather than guess again, this class now sidesteps
    /// live parameter modulation entirely: each `setIntensity` call stops
    /// whatever's playing and starts a BRAND NEW pattern with the desired
    /// intensity baked in as a static event parameter, only when the
    /// intensity actually changes (guarded by `lastIntensity`, so a steady
    /// rumble doesn't rebuild on every repeated identical message). Any
    /// throw from that rebuild is reported via `onError` instead of being
    /// silently dropped.
    private final class HapticChannel {
        let engine: CHHapticEngine
        private var player: CHHapticPatternPlayer?
        private var lastIntensity: Double = -1
        var onError: ((String) -> Void)?

        init(engine: CHHapticEngine) {
            self.engine = engine
        }

        func setIntensity(_ value: Double) {
            let clamped = min(max(value, 0), 1)
            guard abs(clamped - lastIntensity) > 0.001 else { return }
            lastIntensity = clamped
            try? player?.stop(atTime: CHHapticTimeImmediate)
            player = nil
            guard clamped > 0 else { return }
            do {
                // Sharpness scales with intensity instead of a flat 0.5: low-
                // strength rumble (e.g. a light controller nudge) reads as a
                // duller, lower-frequency thud, while strong rumble (impacts,
                // explosions) reads as a sharper, higher-frequency buzz.
                // CoreHaptics is the generic bridge Apple uses to drive
                // whatever actuator the controller actually has — including
                // Nintendo's HD Rumble LRA motors, confirmed working on a
                // real Switch controller — so there's no separate "HD
                // Rumble" API to target; this just uses more of the range
                // CoreHaptics already exposes.
                let sharpness = Float(0.3 + clamped * 0.5)
                let event = CHHapticEvent(
                    eventType: .hapticContinuous,
                    parameters: [
                        CHHapticEventParameter(parameterID: .hapticIntensity, value: Float(clamped)),
                        CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness),
                    ],
                    relativeTime: 0,
                    duration: 86_400 // 24h — replaced wholesale on the next intensity change anyway
                )
                let pattern = try CHHapticPattern(events: [event], parameters: [])
                let newPlayer = try engine.makePlayer(with: pattern)
                try newPlayer.start(atTime: CHHapticTimeImmediate)
                player = newPlayer
            } catch {
                onError?(error.localizedDescription)
            }
        }

        func stop() {
            try? player?.stop(atTime: CHHapticTimeImmediate)
            player = nil
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
    private func applyRumble(id: String, left rawLeft: Double, right rawRight: Double) {
        // User's own toggle/intensity preference applied here, right before
        // CoreHaptics — NOT at the diagnostic-capture site in handleIncoming,
        // so rumbleLastLeft/rumbleLastRight keep showing the server's raw
        // values regardless of what the user has dialed in.
        let left = rumbleEnabled ? min(max(rawLeft * rumbleIntensityMultiplier, 0), 1) : 0
        let right = rumbleEnabled ? min(max(rawRight * rumbleIntensityMultiplier, 0), 1) : 0

        guard let targetId = Int(id),
              let key = controllerIds.first(where: { $0.value == targetId })?.key,
              let controller = GCController.controllers().first(where: { ObjectIdentifier($0) == key })
        else { return }

        // BUG FIX (round 3, 2026-08-09): this cache check used to run AFTER
        // the `controller.haptics` nil-check below. `GCController.haptics`
        // is not a stable capability flag on some hardware — it can flip
        // back to nil on later polls even after an engine was already
        // created from it (BLE re-negotiation, system momentarily
        // reclaiming the haptics engine, etc). With the old ordering, any
        // such nil blip made this function bail out *before* reaching the
        // cache, silently dropping that rumble update to an
        // already-working HapticChannel and stomping
        // rumbleHapticsAvailable back to false — which is consistent with
        // the user seeing "Haptics: no" after previously confirmed "yes"
        // with no other code change. Checking the cache first means once a
        // channel exists we never need `controller.haptics` again — we
        // already own the engine/player.
        if let existing = hapticsByController[key] {
            existing.update(left: left, right: right)
            return
        }

        guard let haptics = controller.haptics else {
            // DIAGNOSTIC: GameController itself says this controller has no
            // haptics support at all — most likely explanation for "rumble
            // does nothing" if rumbleMessagesReceived is climbing but
            // nothing vibrates. Not something CoreHaptics code can route
            // around; the controller/firmware genuinely doesn't expose it.
            rumbleHapticsAvailable = false
            return
        }
        guard left > 0 || right > 0 else { return }
        rumbleHapticsAvailable = true
        guard let created = makeControllerHaptics(haptics: haptics) else { return }
        hapticsByController[key] = created
        created.update(left: left, right: right)
    }

    /// Prefers distinct left/right motor channels when the controller
    /// reports both localities (CONFIRMED available on DualSense/DualShock
    /// via GCDeviceHaptics.supportedLocalities); otherwise falls back to one
    /// shared `.default` channel.
    private func makeControllerHaptics(haptics: GCDeviceHaptics) -> ControllerHaptics? {
        let supported = haptics.supportedLocalities
        rumbleSupportedLocalities = supported.isEmpty ? "(empty)" : supported.map { "\($0.rawValue)" }.sorted().joined(separator: ", ")
        if supported.contains(.leftHandle), supported.contains(.rightHandle) {
            let left = makeChannel(haptics: haptics, locality: .leftHandle)
            let right = makeChannel(haptics: haptics, locality: .rightHandle)
            guard left != nil || right != nil else { return nil }
            return ControllerHaptics(left: left, right: right, combined: nil)
        }
        // DIAGNOSTIC round 2 (2026-08-09): prefer `.all` over `.default` when
        // available — `.default` names one specific actuator, which on some
        // controllers may not correspond to any real motor even though
        // engine creation for it succeeds with no error; `.all` is
        // documented as "every haptic actuator available", the most likely
        // to actually reach whatever motor(s) this controller has.
        let locality: GCHapticsLocality = supported.contains(.all) ? .all : .default
        guard let combined = makeChannel(haptics: haptics, locality: locality) else { return nil }
        return ControllerHaptics(left: nil, right: nil, combined: combined)
    }

    /// Creates and starts just the engine for one locality — the actual
    /// pattern/player is built lazily (and rebuilt on every real intensity
    /// change) by HapticChannel itself, see its doc comment for why.
    private func makeChannel(haptics: GCDeviceHaptics, locality: GCHapticsLocality) -> HapticChannel? {
        guard let engine = haptics.createEngine(withLocality: locality) else {
            rumbleSetupError = "createEngine(withLocality: \(locality)) returned nil"
            return nil
        }
        // Matches Apple's own sample code for GCController-backed engines:
        // this engine only ever plays haptics, never audio, so it doesn't
        // need to negotiate an AVAudioSession category at all.
        engine.playsHapticsOnly = true
        do {
            try engine.start()
        } catch {
            rumbleSetupError = error.localizedDescription
            return nil
        }
        let channel = HapticChannel(engine: engine)
        channel.onError = { [weak self] message in self?.rumbleSendError = message }
        return channel
    }
}
