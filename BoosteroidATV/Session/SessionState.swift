import Foundation

// MARK: - Stream Settings

struct StreamSettings: Codable, Equatable {
    var resolution: String = "1920x1080"
    var fps: Int = 60
    var maxBitrateKbps: Int = 20_000 { didSet { maxBitrateKbps = min(maxBitrateKbps, 100_000) } }
    var codec: VideoCodec = .h264
    var micEnabled: Bool = false
    /// Radial deadzone applied to analog stick axes (0.0–1.0). Default 15%.
    var controllerDeadzone: Double = 0.15
}

enum VideoCodec: String, Codable, CaseIterable {
    case h264 = "H264"
    case h265 = "H265"
    case av1  = "AV1"
}

// MARK: - ICE Server
//
// CONFIRMED shape — this is the literal JSON returned by
// GET {node}/webrtc/api/getIceServers?sessionId=... during a live session:
//   {"iceServers":[{"credential":"...","urls":["turn:HOST:3478?transport=udp"],
//     "username":"<unixSeconds>:boosteroid"}],"iceTransportPolicy":"all"}

struct IceServer: Codable {
    let urls: [String]
    let username: String?
    let credential: String?
}

// MARK: - Session Info
//
// CONFIRMED fields: `sessionId` and `nodeBaseUrl` (e.g.
// "https://sp0.cloud.boosteroid.com") are real — the streaming client page at
// cloud.boosteroid.com/static/streaming/streaming.html?sessionId={uuid} calls
// the WebRTC signaling REST API (getIceServers, getParams, call,
// addIceCandidate, getIceCandidate — see SignalingClient.swift) against
// exactly this kind of per-node host.
//
// TODO(protocol): the exact response body of
// POST /api/v1/streaming/session/details?sessionId=... (which almost
// certainly carries `nodeBaseUrl`, and maybe `status`/queue info) was not
// captured — its field names below are inferred, not observed byte-for-byte.
struct SessionInfo {
    let sessionId: String
    let nodeBaseUrl: String
    let status: Int
    let queuePosition: Int?

    var isInQueue: Bool { (queuePosition ?? 0) > 0 }
}

struct ActiveSessionInfo {
    let sessionId: String
    let status: Int
    let gameId: String?
}

// MARK: - Games
//
// CONFIRMED: individual game/catalog entries are fetched via
// GET /api/v1/boostore/applications/{numericId} (e.g. .../applications/836 for
// eFootball). The dashboard's "Os meus jogos" grid and the hero carousel
// (GET /api/v1/boostore/carousel?isSub=true) are also real endpoints, but the
// exact JSON shape of any of these responses wasn't captured — only that they
// exist, their URLs, and that `id` is a small integer (not a GUID/slug).
// TODO(protocol): capture one real `applications/{id}` response body to fill
// in the actual field names (title, box art URL, store/ownership info, launch
// requirements like "needs a linked Steam account" — seen in the UI as a
// pre-launch modal).
struct GameInfo: Identifiable, Equatable {
    let id: String
    let title: String
    let boxArtUrl: String?
    var isInLibrary: Bool
}

// MARK: - Session Create Request
//
// CONFIRMED: POST /api/v2/streaming/session/enqueue → 204 (no observed
// response body) is what actually kicks off a session; the UI then shows a
// "Posição na fila" (queue position) screen and eventually redirects to the
// streaming.html page with a sessionId. TODO(protocol): the exact request
// body sent to /enqueue wasn't captured (blocked by the browser tool's
// exfil-prevention filter on raw JS dumps) — likely at minimum the numeric
// application id and requested resolution/fps.
struct SessionCreateRequest {
    let gameId: String
    let settings: StreamSettings
}
