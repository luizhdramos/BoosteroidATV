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
// CONFIRMED 2026-07-22 live (fetch-patch finally caught real traffic on a
// second capture pass, after the first two attempts on the enqueue call came
// back empty): `GET /api/v1/streaming/user/last-session` returns
//   {"data":{"sessionId":"<uuid>","appId":<int>,"status":"EN"}}
// "EN" was observed for a session sitting in queue. TODO(protocol): the
// status value once a session goes live was NOT captured — the only queue
// watched in this pass sat at position ~52-55 the whole time (Boosteroid's
// free-tier queue position can climb, not just fall, as paying-tier users
// cut ahead) and a separate stale session from an earlier capture pass had
// already timed out server-side by the time it was checked again. Treat
// "EN" as "still queued" and any other status as "worth trying
// session/details".
//
// CONFIRMED: `POST /api/v1/streaming/session/details?sessionId=...` is
// POST-only (a GET returns 405 with a body naming POST as the only
// supported method). For an actually-expired session it returns HTTP 406
// with:
//   {"data":{"title":"TIMEOUT!","message":"Session has been ended by
//   timeout","icon":"cry","code":"timeout"}}
// TODO(protocol): the SUCCESS body (which should carry `nodeBaseUrl`, e.g.
// "https://sp0.cloud.boosteroid.com" — confirmed as a real per-node host
// from the earlier eFootball capture, just not re-confirmed as THIS
// endpoint's field) was not captured — no session in this pass reached
// "active" before timing out.
struct SessionInfo {
    let sessionId: String
    var nodeBaseUrl: String?
    let status: String

    var isInQueue: Bool { status == "EN" }
}

/// CONFIRMED shape of `GET /api/v1/streaming/user/last-session`'s `data`
/// object — see SessionInfo doc comment above.
struct BoosteroidLastSessionDTO: Codable {
    struct Payload: Codable {
        let sessionId: String
        let appId: Int
        let status: String
    }
    let data: Payload
}

/// CONFIRMED shape of `POST /api/v1/streaming/session/details`'s error body
/// for an expired/timed-out session (HTTP 406) — see SessionInfo doc comment.
struct BoosteroidSessionDetailsErrorDTO: Codable {
    struct Payload: Codable {
        let title: String?
        let message: String?
        let icon: String?
        let code: String?
    }
    let data: Payload
}

struct ActiveSessionInfo {
    let sessionId: String
    let status: String
    let gameId: String?
}

// MARK: - Games
//
// CONFIRMED 2026-07-22 live from a logged-in browser session:
// GET /api/v1/boostore/applications/installed?page=1&paginate=50 is the
// "list my library" endpoint (never found in the earlier capture pass, which
// assumed it might be SSR-embedded instead — it isn't). Standard Laravel
// pagination envelope: {"data":[...],"links":{...},"meta":{...}}. Each
// element of `data` has (confirmed field names/types):
//   id: Int, name: String, icon: String (URL, CONFIRMED 200x200 square),
//   bannerImage: String (URL, CONFIRMED 2560x1440 = 16:9 landscape — use for
//   a future hero/banner section, NOT the grid; using it there produced
//   badly-cropped "truncated"-looking tiles), installed: Bool, genre/tags:
//   arrays, platform/stores: objects, plus publisher/developer/maintenance/
//   unavailable/monetizeType/controller/launchLimit/underEula/isOptimized/
//   cardColor/storePromo/createdAt — present but not yet needed, so not
//   decoded below (Codable ignores unknown keys).
// GET /api/v1/boostore/applications/{id} (single game) and
// GET /api/v1/boostore/carousel?isSub=true (hero banner) presumably share
// this same per-application shape; TODO(protocol) confirm once used.
struct BoosteroidApplicationDTO: Codable {
    let id: Int
    let name: String
    let icon: String?
    let bannerImage: String?
    let installed: Bool
}

struct BoosteroidPaginatedApplications: Codable {
    let data: [BoosteroidApplicationDTO]
}

struct GameInfo: Identifiable, Equatable {
    let id: String
    let title: String
    let boxArtUrl: String?
    var isInLibrary: Bool

    init(id: String, title: String, boxArtUrl: String?, isInLibrary: Bool) {
        self.id = id
        self.title = title
        self.boxArtUrl = boxArtUrl
        self.isInLibrary = isInLibrary
    }

    init(_ dto: BoosteroidApplicationDTO) {
        self.id = String(dto.id)
        self.title = dto.name
        // `icon` (square) for grid tiles — `bannerImage` is a wide 16:9
        // banner, wrong shape for the portrait/square tiles HomeView draws.
        self.boxArtUrl = dto.icon ?? dto.bannerImage
        self.isInLibrary = dto.installed
    }
}

// MARK: - Session Create Request
//
// CONFIRMED 2026-07-22 live (real captured request body):
//   POST /api/v2/streaming/session/enqueue
//   body: {"appId": <int>}
//   → 204, no response body.
// The UI then shows a "Posição na fila" (queue position) screen; the actual
// sessionId/status for that queue is retrieved via a follow-up call to
// last-session, not from enqueue's (empty) response — see
// BoosteroidClient.createSession. TODO(protocol): whether other fields
// (resolution/fps/region) can also be sent on enqueue is still unconfirmed —
// the real client only sent `appId` in the captured request.
struct SessionCreateRequest {
    let gameId: String
    let settings: StreamSettings
}
