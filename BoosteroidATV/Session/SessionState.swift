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

// MARK: - Current User
//
// CONFIRMED 2026-07-22 live: GET /api/v1/user's success body is
// {"data":{"id":<int>,"name":...,"email":...,"avatar":...,...}} (plus other
// unused-so-far fields — emailVerifiedAt, firstName/lastName, isActive,
// isBlocked, languageCode, socialAuths, ...). `id` matters beyond display:
// it's the numeric `uid` the real web client sends when connecting to
// wss://cloud.boosteroid.com/ws — see BoosteroidRealtimeClient and
// AuthManager.resolveRealtimeCredentials. Shared between BoosteroidAuthAPI
// (login) and BoosteroidClient (fetchCurrentUser) since both need it.
struct BoosteroidUserResponseDTO: Codable {
    struct Payload: Codable {
        let id: Int
        let name: String
        let email: String?
        let avatar: String?
    }
    let data: Payload
}

// MARK: - Session Info
//
// CONFIRMED 2026-07-22 live end-to-end: `GET /api/v1/streaming/user/
// last-session` returns
//   {"data":{"sessionId":"<uuid>","appId":<int>,"status":"EN"}}
// while queued, and status flips to `"LI"` ("Live", presumably) once the
// session is genuinely active — verified by watching a real, paying-tier
// account's queue drain and PRAGMATA actually become playable. (An earlier
// pass through this investigation saw last-session apparently "stuck" on a
// stale, already-expired session no matter how many fresh enqueue calls
// were made — that turned out to be specific to one leftover session, not a
// general reliability problem with this endpoint; see BoosteroidClient's
// Session Lifecycle note for the full story.) Queue POSITION (the number
// the web UI shows) is a separate concept, pushed over a WebSocket — see
// BoosteroidRealtimeClient — not present on last-session at all.
//
// CONFIRMED: `POST /api/v1/streaming/session/details?sessionId=...` is
// POST-only (a GET returns 405 with a body naming POST as the only
// supported method). For an actually-expired session it returns HTTP 406
// with:
//   {"data":{"title":"TIMEOUT!","message":"Session has been ended by
//   timeout","icon":"cry","code":"timeout"}}
//
// CONFIRMED 2026-07-22, second pass, against a genuinely active PRAGMATA
// session that made it all the way through a real (if slow — a paying
// account's queue drained ~53 -> 0 over a few minutes) queue: the SUCCESS
// body is
//   {"data":{"gw":"https://sp7.cloud.boosteroid.com:443",
//            "queryString":"<JWT>"}}
// `gw` is exactly `SessionInfo.nodeBaseUrl` — confirmed by then watching
// the real client make its `getIceServers`/`getParams`/`call`/
// `addIceCandidate`/`getIceCandidate` calls against that exact host,
// matching SignalingClient.swift's existing (already-correct) URL
// patterns byte-for-byte. `queryString` is a JWT whose payload decodes to
// `{userId, nickName, applicationName, applicationId, sessionId,
// platformUid, merchantId, domain, language, viewers, idleTimeout,
// reconnectTimeout, hasSubscription, performanceTypes, streamingToken,
// allowedPlaygrounds}` — confirms e.g. `hasSubscription`/`performanceTypes`
// reflect the real account's plan. CONFIRMED 2026-07-23 (previously
// documented as "not observed being sent anywhere" — wrong, just not yet
// found): it's never sent to the `webrtc/api/*` media-signaling calls, but
// it IS the required auth for the separate control WebSocket that carries
// all keyboard/mouse/controller input — see BoosteroidControlChannel.
struct SessionInfo {
    let sessionId: String
    var nodeBaseUrl: String?
    let status: String
    /// CONFIRMED 2026-07-23 via static analysis of streaming.js: this is
    /// `session/details`'s `data.queryString` JWT, previously fetched and
    /// stored but never actually used anywhere. It turns out to be required
    /// — it's the auth for the control WebSocket that carries ALL input
    /// (keyboard/mouse/controller), not just informative metadata. See
    /// BoosteroidControlChannel's header comment for the full protocol.
    var queryString: String? = nil

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

/// CONFIRMED shape of `POST /api/v1/streaming/session/details`'s SUCCESS
/// body (HTTP 200) — see SessionInfo doc comment above.
struct BoosteroidSessionDetailsSuccessDTO: Codable {
    struct Payload: Codable {
        let gw: String
        let queryString: String?
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
