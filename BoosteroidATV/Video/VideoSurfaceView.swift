// NOTE: Requires WebRTC SPM package (https://github.com/livekit/webrtc-xcframework)

import AVFoundation
import GameController
import UIKit
import LiveKitWebRTC

// MARK: - VideoSurfaceView
//
// Full-screen video renderer. Uses AVSampleBufferDisplayLayer as the backing
// layer (reliable on tvOS — LKRTCMTLVideoView does not render on tvOS).
//
// This file is almost entirely protocol-agnostic: WebRTC frame rendering and
// the HID → Windows-VK/scancode keyboard mapping are the same regardless of
// which cloud-gaming backend is on the other end (assuming, like GFN, the
// remote host is Windows — TODO(protocol): confirm Boosteroid's game hosts are
// Windows-based; if not, the VK/scancode table below is meaningless and
// InputSender needs a different key encoding entirely).
final class VideoSurfaceView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    private var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }
    private let renderer = WebRTCFrameRenderer()
    private var currentTrack: LKRTCVideoTrack?

    /// Set by StreamController once the input channel is ready.
    weak var inputHandler: InputEventHandler?

    /// Called when the user presses the Menu button on the Siri Remote.
    var menuPressHandler: (() -> Void)?

    /// Reports where the remote cursor now is, in the streamed surface's pixels,
    /// so the UI can draw the pointer there. Accurate because pointer mode pins
    /// the cursor to a known corner on activation (see calibratePointer).
    var pointerPositionHandler: ((CGPoint) -> Void)?

    /// When true, an extended gamepad owns input.
    var gamepadModeActive = false

    /// When true, the Siri Remote's touch surface drives the mouse pointer and
    /// the centre click sends a left button. Off by default so the remote keeps
    /// behaving as a gamepad for normal play.
    var pointerModeActive = false {
        didSet {
            guard pointerModeActive != oldValue else { return }
            pointerPanRecognizer?.isEnabled = pointerModeActive
            pointerTapRecognizer?.isEnabled = pointerModeActive
            if pointerModeActive { calibratePointer() }
        }
    }
    private weak var pointerPanRecognizer: UIPanGestureRecognizer?
    private weak var pointerTapRecognizer: UITapGestureRecognizer?

    /// Pointer position in the streamed surface's pixels, tracked so pointer
    /// mode can send ABSOLUTE coordinates. Relative movement is confirmed but
    /// is what we send; this is only our own tracking of where it must have
    /// ended up, kept accurate by calibratePointer.
    private var absolutePointer: CGPoint?
    /// The streamed surface size, needed to clamp and to start at its centre.
    var streamSurfaceSize: CGSize = CGSize(width: 1920, height: 1080)
    /// Last pan translation, so movement can be sent as deltas.
    private var lastPanTranslation: CGPoint = .zero

    /// Tracks whether the pause overlay is currently visible.
    var overlayVisible: Bool = false

    var videoTrack: LKRTCVideoTrack? {
        didSet {
            guard oldValue !== videoTrack else { return }
            currentTrack?.remove(renderer)
            currentTrack = videoTrack
            if let track = videoTrack {
                track.add(renderer)
                print("[VideoSurfaceView] Track attached")
            }
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        backgroundColor = .black
        displayLayer.videoGravity = .resizeAspectFill
        var tb: CMTimebase?
        CMTimebaseCreateWithSourceClock(allocator: nil, sourceClock: CMClockGetHostTimeClock(), timebaseOut: &tb)
        if let tb {
            CMTimebaseSetTime(tb, time: CMClockGetTime(CMClockGetHostTimeClock()))
            CMTimebaseSetRate(tb, rate: 1.0)
            displayLayer.controlTimebase = tb
        }
        renderer.displayLayer = displayLayer
        setupPointerGesture()
    }

    /// A pan recognizer over the Siri Remote's touch surface, translated into
    /// RELATIVE mouse movement — the same shape `InputSender.sendMouseMove`
    /// already speaks, so nothing new is needed on the protocol side.
    private func setupPointerGesture() {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePointerPan(_:)))
        pan.isEnabled = false // only while pointer mode is on
        addGestureRecognizer(pan)
        pointerPanRecognizer = pan

        // The centre click as a TAP recognizer rather than via pressesBegan.
        // On tvOS the select press is what a gesture recognizer on the same view
        // competes for, and handling it in pressesBegan meant the click never
        // arrived once the pan recognizer was active — reported as "the pointer
        // moves but clicking does nothing". `allowedPressTypes` is the canonical
        // way to catch it.
        let tap = UITapGestureRecognizer(target: self, action: #selector(handlePointerTap))
        tap.allowedPressTypes = [NSNumber(value: UIPress.PressType.select.rawValue)]
        tap.isEnabled = false
        addGestureRecognizer(tap)
        pointerTapRecognizer = tap
    }

    /// A tap is a press and release in quick succession — enough for clicking
    /// buttons, which is what pointer mode is for. Dragging would need the
    /// down/up split and isn't supported yet.
    /// Places the pointer at the centre of the surface when pointer mode starts.
    ///
    /// No calibration trick is needed any more: absolute positioning means we
    /// state where the cursor goes, so it simply arrives there. (An earlier pass
    /// slammed the cursor into the top-left corner to give dead-reckoning a
    /// known origin — that was only necessary while we were stuck sending
    /// relative movement.)
    private func calibratePointer() {
        let centre = CGPoint(x: streamSurfaceSize.width / 2, y: streamSurfaceSize.height / 2)
        absolutePointer = centre
        inputHandler?.sendMouseAbsolute(x: Int(centre.x), y: Int(centre.y))
        pointerPositionHandler?(centre)
    }

    @objc private func handlePointerTap() {
        inputHandler?.sendMouseButton(down: true, button: 0)
        inputHandler?.sendMouseButton(down: false, button: 0)
        pointerClickedHandler?()
    }

    /// Fired on every click actually recognised, so the UI can show whether the
    /// tap is even reaching us. Without this, "clicking does nothing" can't be
    /// told apart from the gesture never firing.
    var pointerClickedHandler: (() -> Void)?

    @objc private func handlePointerPan(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            lastPanTranslation = .zero
        case .changed:
            let translation = gesture.translation(in: self)
            // Deltas, not absolute positions: the surface reports a running
            // translation, so subtract what was already sent.
            let dx = translation.x - lastPanTranslation.x
            let dy = translation.y - lastPanTranslation.y
            lastPanTranslation = translation
            // Scale down: a full swipe across the small touch surface would
            // otherwise fling the cursor across a 4K desktop.
            let scale: CGFloat = 0.35
            let sx = Int16(clamping: Int(dx * scale))
            let sy = Int16(clamping: Int(dy * scale))
            guard sx != 0 || sy != 0 else { return }

            // ABSOLUTE positioning — the mode the web client uses for a desktop
            // or launcher, now that its real message shape is known (see
            // InputSender.sendMouseAbsolute). We own the position, so the remote
            // cursor lands exactly under the drawn arrow instead of drifting.
            var position = absolutePointer ?? CGPoint(x: streamSurfaceSize.width / 2,
                                                      y: streamSurfaceSize.height / 2)
            position.x = min(max(position.x + CGFloat(sx), 0), streamSurfaceSize.width)
            position.y = min(max(position.y + CGFloat(sy), 0), streamSurfaceSize.height)
            absolutePointer = position
            inputHandler?.sendMouseAbsolute(x: Int(position.x), y: Int(position.y))
            pointerPositionHandler?(position)
        case .ended, .cancelled, .failed:
            lastPanTranslation = .zero
        default:
            break
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            becomeFirstResponder()
        }
    }

    // MARK: - First Responder / Keyboard

    override var canBecomeFirstResponder: Bool { true }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for press in presses {
            if press.type == .playPause {
                // Play/Pause toggles the in-stream bar open/closed — the
                // ONLY way to reach it now. Menu/Back ("<") is deliberately
                // left unhandled here (falls through to super below), so it
                // keeps its natural system behavior of dismissing this
                // presented fullScreenCover and returning Home — by design,
                // per feedback: trying to make Back open/close our own bar
                // never reliably stuck. See StreamView's .onDisappear note:
                // that natural Back-triggered dismissal is safe precisely
                // because disconnect() there only tears down THIS device's
                // local connection, not the actual cloud session.
                menuPressHandler?()
                handled = true
            } else if press.type == .menu {
                // CONFIRMED (2026-08-02, reported as "Start e Select não
                // estão funcionando... antes estava"): tvOS treats a REAL
                // game controller's own Menu/Start button as an ordinary
                // system .menu UIPress, exactly like the Siri Remote's own
                // Back/"<" button — documented Apple behavior, not specific
                // to this app. Since Menu/Back is deliberately left
                // unhandled above (falls to super, which dismisses this
                // presented fullScreenCover), a real controller's Start
                // button was ALSO silently exiting the stream back to Home.
                //
                // The first fix (just swallowing this press) stopped the
                // unwanted exit, but Start still never reached the GAME —
                // CONFIRMED 2026-08-08: with controllerUserInteractionEnabled
                // == false, GCExtendedGamepad.buttonMenu's isPressed/
                // valueChangedHandler never fires at all; the OS redirects
                // the press here, to pressesBegan, INSTEAD of updating that
                // state. So InputSender's ~60Hz pollGamepad — which is what
                // forwards every other button — can never see this one no
                // matter what we do here; it has to be sent explicitly. See
                // InputEventHandler.sendControllerMenuButton's doc comment.
                //
                // Only the Siri Remote should get the natural dismiss-to-
                // Home behavior; GCController.current is set to whichever
                // controller most recently produced input, which at this
                // exact moment is the one that sent THIS press (same
                // technique InputSender.pollGamepad already uses to tell
                // them apart).
                let isSiriRemote = GCController.current?.microGamepad != nil
                if !isSiriRemote {
                    inputHandler?.sendControllerMenuButton(pressed: true)
                    handled = true
                }
            } else if let key = press.key, let mapping = Self.hidToKeyMapping[key.keyCode] {
                inputHandler?.sendKeyEvent(
                    down: true,
                    vk: mapping.vk,
                    scancode: mapping.scancode,
                    modifiers: modifierBits(from: key.modifierFlags)
                )
                handled = true
            }
        }
        if !handled { super.pressesBegan(presses, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for press in presses {
            if press.type == .menu, GCController.current?.microGamepad == nil {
                // Mirrors pressesBegan's .menu handling — sends the release
                // half of the same Start button press. (No matching branch
                // needed for the Siri Remote's own Back button: the
                // system's default dismiss action already fires on the
                // "began" phase, so its "ended" phase falling through to
                // super here is a no-op, same as it always was.)
                inputHandler?.sendControllerMenuButton(pressed: false)
                handled = true
            } else if let key = press.key, let mapping = Self.hidToKeyMapping[key.keyCode] {
                inputHandler?.sendKeyEvent(
                    down: false,
                    vk: mapping.vk,
                    scancode: mapping.scancode,
                    modifiers: modifierBits(from: key.modifierFlags)
                )
                handled = true
            }
        }
        if !handled { super.pressesEnded(presses, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        pressesEnded(presses, with: event)
    }

    // MARK: - Helpers

    private func modifierBits(from flags: UIKeyModifierFlags) -> UInt16 {
        var mods: UInt16 = 0
        if flags.contains(.shift)     { mods |= 0x0001 }
        if flags.contains(.control)   { mods |= 0x0002 }
        if flags.contains(.alternate) { mods |= 0x0004 }
        if flags.contains(.command)   { mods |= 0x0008 }
        return mods
    }

    // MARK: - HID → (VK, Scancode) Table
    //
    // Maps UIKeyboardHIDUsage (USB HID Usage codes) to Windows Virtual Key codes
    // and PS/2 Set-1 scancodes. Extended scancodes (0xE0 prefix) are stored as-is
    // in the UInt16 high byte (0xE0__).

    private static let hidToKeyMapping: [UIKeyboardHIDUsage: (vk: UInt16, scancode: UInt16)] = [
        // Letters A–Z  (VK = ASCII uppercase, scancode = PS/2 Set-1)
        .keyboardA: (0x41, 0x1E), .keyboardB: (0x42, 0x30), .keyboardC: (0x43, 0x2E),
        .keyboardD: (0x44, 0x20), .keyboardE: (0x45, 0x12), .keyboardF: (0x46, 0x21),
        .keyboardG: (0x47, 0x22), .keyboardH: (0x48, 0x23), .keyboardI: (0x49, 0x17),
        .keyboardJ: (0x4A, 0x24), .keyboardK: (0x4B, 0x25), .keyboardL: (0x4C, 0x26),
        .keyboardM: (0x4D, 0x32), .keyboardN: (0x4E, 0x31), .keyboardO: (0x4F, 0x18),
        .keyboardP: (0x50, 0x19), .keyboardQ: (0x51, 0x10), .keyboardR: (0x52, 0x13),
        .keyboardS: (0x53, 0x1F), .keyboardT: (0x54, 0x14), .keyboardU: (0x55, 0x16),
        .keyboardV: (0x56, 0x2F), .keyboardW: (0x57, 0x11), .keyboardX: (0x58, 0x2D),
        .keyboardY: (0x59, 0x15), .keyboardZ: (0x5A, 0x2C),

        // Digit row  (VK = ASCII digit)
        .keyboard1: (0x31, 0x02), .keyboard2: (0x32, 0x03), .keyboard3: (0x33, 0x04),
        .keyboard4: (0x34, 0x05), .keyboard5: (0x35, 0x06), .keyboard6: (0x36, 0x07),
        .keyboard7: (0x37, 0x08), .keyboard8: (0x38, 0x09), .keyboard9: (0x39, 0x0A),
        .keyboard0: (0x30, 0x0B),

        // Control / whitespace
        .keyboardReturnOrEnter:     (0x0D, 0x1C),
        .keyboardEscape:            (0x1B, 0x01),
        .keyboardDeleteOrBackspace: (0x08, 0x0E),
        .keyboardTab:               (0x09, 0x0F),
        .keyboardSpacebar:          (0x20, 0x39),
        .keyboardCapsLock:          (0x14, 0x3A),

        // Symbols
        .keyboardHyphen:               (0xBD, 0x0C),
        .keyboardEqualSign:            (0xBB, 0x0D),
        .keyboardOpenBracket:          (0xDB, 0x1A),
        .keyboardCloseBracket:         (0xDD, 0x1B),
        .keyboardBackslash:            (0xDC, 0x2B),
        .keyboardNonUSPound:           (0xE2, 0x56),
        .keyboardSemicolon:            (0xBA, 0x27),
        .keyboardQuote:                (0xDE, 0x28),
        .keyboardGraveAccentAndTilde:  (0xC0, 0x29),
        .keyboardComma:                (0xBC, 0x33),
        .keyboardPeriod:               (0xBE, 0x34),
        .keyboardSlash:                (0xBF, 0x35),

        // Function keys F1–F13
        .keyboardF1:  (0x70, 0x3B), .keyboardF2:  (0x71, 0x3C), .keyboardF3:  (0x72, 0x3D),
        .keyboardF4:  (0x73, 0x3E), .keyboardF5:  (0x74, 0x3F), .keyboardF6:  (0x75, 0x40),
        .keyboardF7:  (0x76, 0x41), .keyboardF8:  (0x77, 0x42), .keyboardF9:  (0x78, 0x43),
        .keyboardF10: (0x79, 0x44), .keyboardF11: (0x7A, 0x57), .keyboardF12: (0x7B, 0x58),
        .keyboardF13: (0x7C, 0x64),

        // Navigation cluster (extended scancodes: 0xE0 in high byte)
        .keyboardInsert:      (0x2D, 0xE052), .keyboardHome:     (0x24, 0xE047),
        .keyboardPageUp:      (0x21, 0xE049), .keyboardDeleteForward: (0x2E, 0xE053),
        .keyboardEnd:         (0x23, 0xE04F), .keyboardPageDown:  (0x22, 0xE051),
        .keyboardRightArrow:  (0x27, 0xE04D), .keyboardLeftArrow: (0x25, 0xE04B),
        .keyboardDownArrow:   (0x28, 0xE050), .keyboardUpArrow:   (0x26, 0xE048),

        // System keys
        .keyboardPrintScreen: (0x2C, 0xE037),
        .keyboardScrollLock:  (0x91, 0x46),
        .keyboardPause:       (0x13, 0x45),
        .keyboardApplication: (0x5D, 0xE05D),

        // Numpad
        .keypadNumLock:   (0x90, 0xE045),
        .keypadSlash:     (0x6F, 0xE035),
        .keypadAsterisk:  (0x6A, 0x37),
        .keypadHyphen:    (0x6D, 0x4A),
        .keypadPlus:      (0x6B, 0x4E),
        .keypadEnter:     (0x0D, 0xE01C),
        .keypad1:         (0x61, 0x4F), .keypad2: (0x62, 0x50), .keypad3: (0x63, 0x51),
        .keypad4:         (0x64, 0x4B), .keypad5: (0x65, 0x4C), .keypad6: (0x66, 0x4D),
        .keypad7:         (0x67, 0x47), .keypad8: (0x68, 0x48), .keypad9: (0x69, 0x49),
        .keypad0:         (0x60, 0x52), .keypadPeriod: (0x6E, 0x53),

        // Modifier keys
        .keyboardLeftControl:  (0xA2, 0x1D),   .keyboardRightControl: (0xA3, 0xE01D),
        .keyboardLeftShift:    (0xA0, 0x2A),   .keyboardRightShift:   (0xA1, 0x36),
        .keyboardLeftAlt:      (0xA4, 0x38),   .keyboardRightAlt:     (0xA5, 0xE038),
        .keyboardLeftGUI:      (0x5B, 0xE05B), .keyboardRightGUI:     (0x5C, 0xE05C),
    ]
}

// MARK: - WebRTC Video Renderer

private final class WebRTCFrameRenderer: NSObject, LKRTCVideoRenderer {
    weak var displayLayer: AVSampleBufferDisplayLayer?

    func setSize(_ size: CGSize) {}

    func renderFrame(_ frame: LKRTCVideoFrame?) {
        guard let frame else { return }

        let cvBuf: CVPixelBuffer
        if let hwBuf = frame.buffer as? LKRTCCVPixelBuffer {
            cvBuf = hwBuf.pixelBuffer
        } else if let i420 = frame.buffer as? LKRTCI420Buffer {
            guard let converted = i420ToCVPixelBuffer(i420) else { return }
            cvBuf = converted
        } else {
            print("[WebRTCFrameRenderer] Unhandled frame type: \(type(of: frame.buffer))")
            return
        }

        var fmtDesc: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: cvBuf, formatDescriptionOut: &fmtDesc)
        guard let fmtDesc else { return }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        CMSampleBufferCreateForImageBuffer(
            allocator: nil,
            imageBuffer: cvBuf,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: fmtDesc,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )
        guard let sampleBuffer else { return }
        displayLayer?.enqueue(sampleBuffer)
    }

    private func i420ToCVPixelBuffer(_ i420: LKRTCI420Buffer) -> CVPixelBuffer? {
        let w = Int(i420.width), h = Int(i420.height)
        var pb: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, w, h,
                                  kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, nil, &pb) == kCVReturnSuccess,
              let pb else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }

        if let dst = CVPixelBufferGetBaseAddressOfPlane(pb, 0) {
            let src = i420.dataY
            let dstStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
            for row in 0..<h {
                memcpy(dst.advanced(by: row * dstStride), src.advanced(by: row * Int(i420.strideY)), w)
            }
        }

        if let dst = CVPixelBufferGetBaseAddressOfPlane(pb, 1)?.assumingMemoryBound(to: UInt8.self) {
            let srcU = i420.dataU
            let srcV = i420.dataV
            let dstStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
            let uvRows = h / 2, uvCols = w / 2
            for row in 0..<uvRows {
                let uRow = srcU.advanced(by: row * Int(i420.strideU))
                let vRow = srcV.advanced(by: row * Int(i420.strideV))
                let dstRow = dst.advanced(by: row * dstStride)
                for col in 0..<uvCols {
                    dstRow[col * 2]     = uRow[col]
                    dstRow[col * 2 + 1] = vRow[col]
                }
            }
        }
        return pb
    }
}

// MARK: - Streaming View Controller

final class StreamingViewController: GCEventViewController {
    let videoSurface = VideoSurfaceView()

    override func loadView() {
        controllerUserInteractionEnabled = false
        view = videoSurface
    }
}

// MARK: - SwiftUI Wrapper

import SwiftUI

struct VideoSurfaceViewRepresentable: UIViewControllerRepresentable {
    let streamController: StreamController
    var showOverlay: Bool = false
    /// Called when the user presses Menu or Play/Pause on the remote — used to
    /// open the in-stream pause menu (the way back Home).
    var onMenu: () -> Void = {}
    /// Siri Remote touch surface drives the mouse pointer; centre click sends
    /// the left button.
    var pointerMode: Bool = false
    /// Where the remote cursor now is, in streamed-surface pixels.
    var onPointerPosition: (CGPoint) -> Void = { _ in }
    /// Streamed surface size, so absolute pointer coordinates are in the remote
    /// desktop's own pixels.
    var surfaceSize: CGSize = CGSize(width: 1920, height: 1080)
    /// Fired per recognised click, so the UI can prove the tap is arriving.
    var onPointerClicked: () -> Void = {}

    func makeUIViewController(context: Context) -> StreamingViewController {
        let vc = StreamingViewController()
        vc.videoSurface.menuPressHandler = onMenu
        vc.videoSurface.pointerModeActive = pointerMode
        vc.videoSurface.pointerPositionHandler = onPointerPosition
        vc.videoSurface.pointerClickedHandler = onPointerClicked
        vc.videoSurface.streamSurfaceSize = surfaceSize
        Task { @MainActor in
            streamController.bindVideoView(vc.videoSurface)
        }
        return vc
    }

    func updateUIViewController(_ vc: StreamingViewController, context: Context) {
        vc.videoSurface.videoTrack = streamController.videoTrack
        vc.videoSurface.menuPressHandler = onMenu
        vc.videoSurface.pointerModeActive = pointerMode
        vc.videoSurface.pointerPositionHandler = onPointerPosition
        vc.videoSurface.pointerClickedHandler = onPointerClicked
        vc.videoSurface.streamSurfaceSize = surfaceSize
        vc.controllerUserInteractionEnabled = showOverlay
        vc.videoSurface.overlayVisible = showOverlay
    }
}
