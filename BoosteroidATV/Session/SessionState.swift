import Foundation

// MARK: - Stream Settings

nonisolated struct StreamSettings: Codable, Equatable {
    var resolution: String = "1920x1080"
    var fps: Int = 60
    var maxBitrateKbps: Int = 20_000 { didSet { maxBitrateKbps = min(maxBitrateKbps, 100_000) } }
    var codec: VideoCodec = .h264
    var micEnabled: Bool = false
    /// Bitrate control. When automatic, the max bitrate is derived from the
    /// resolution (mirroring Boosteroid's own resolution→bitrate ladder). When
    /// off, `manualBitrateMbps` (3–80 Mbps, like the official client) is used.
    /// Sent to the server as `stream/bandwidth` in bps.
    var automaticBitrate: Bool = true
    var manualBitrateMbps: Int = 20 { didSet { manualBitrateMbps = min(80, max(3, manualBitrateMbps)) } }
    /// Radial deadzone applied to analog stick axes (0.0–1.0). Default 15%.
    var controllerDeadzone: Double = 0.15
    /// Show the in-stream performance overlay (Stream/Decode FPS, latency,
    /// codec & bitrate). Off by default; toggled in Settings.
    var showStatsOverlay: Bool = false
}

nonisolated enum VideoCodec: String, Codable, CaseIterable {
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

nonisolated struct IceServer: Codable {
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
nonisolated struct BoosteroidUserResponseDTO: Codable {
    struct Payload: Codable {
        let id: Int
        let name: String
        let email: String?
        let avatar: String?
        /// CONFIRMED 2026-08-02 live from cloud.boosteroid.com/profile/
        /// account/main (patched fetch/XHR while toggling the real
        /// "Permitir ligação a regiões distantes" switch and reading the
        /// PATCH body back): `false` means the toggle is ON (distant
        /// regions ALLOWED), `true` means it's OFF (restricted to the
        /// account's own region) — inverted vs. the UI label, so callers
        /// should read/write `!onlyMyRegion` as "allow distant regions".
        /// Optional since older/unrelated call sites decoding this same DTO
        /// (login) don't need it and it's harmless if ever absent.
        let onlyMyRegion: Bool?
        /// CONFIRMED 2026-08-02 live: array of BoosteroidPlayground `id`s
        /// the account wants to force streaming to; empty means
        /// "Localização automática". The real web UI only ever puts a
        /// single id in here despite the array shape — CONFIRMED by
        /// picking a server from the dropdown and reading the PATCH body
        /// (`{"preferredPlaygrounds":[6]}`), never more than one entry.
        let preferredPlaygrounds: [Int]?
    }
    let data: Payload
}

// MARK: - Streaming Playgrounds (server locations)
//
// CONFIRMED 2026-08-02 live: `GET /api/v1/streaming/playgrounds` is the data
// behind the account-settings page's "Localização de servidor preferida"
// dropdown — 23 entries observed. Each is a named city/country location with
// one or more physical gateway hosts; `priority: true` marks the
// playground(s) considered "the account's own region" (what "Localização
// automática" uses). This is a DIFFERENT, richer endpoint than the existing
// `/v1/streaming/gateways` used by `preferredGateway(cookies:)` below — that
// one is a flat host list with no location metadata, kept only for its
// original narrow purpose (see its own doc comment).
nonisolated struct BoosteroidPlayground: Codable, Identifiable, Equatable {
    struct Location: Codable, Equatable {
        let country: String
        let city: String
    }
    struct Gateway: Codable, Equatable {
        let name: String
        let address: String
        let active: Bool
        let status: String
    }
    let id: Int
    let title: String
    let location: Location
    let priority: Bool
    let active: Bool
    let status: String
    let gateways: [Gateway]

    /// "Bratislava (Slovakia)" — matches the real web UI's own label text
    /// exactly (confirmed against the live dropdown).
    var displayName: String { "\(title) (\(location.country))" }
}

nonisolated struct BoosteroidPlaygroundsDTO: Codable {
    let data: [BoosteroidPlayground]
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
nonisolated struct SessionInfo {
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
nonisolated struct BoosteroidLastSessionDTO: Codable {
    struct Payload: Codable {
        let sessionId: String
        let appId: Int
        let status: String
    }
    let data: Payload
}

/// CONFIRMED shape of `POST /api/v1/streaming/session/details`'s SUCCESS
/// body (HTTP 200) — see SessionInfo doc comment above.
nonisolated struct BoosteroidSessionDetailsSuccessDTO: Decodable {
    struct Payload: Decodable {
        /// The assigned machine's base URL, e.g. "https://so2.cloud.boosteroid.com:443".
        ///
        /// CONFIRMED 2026-07-24 from streaming.js, which builds its control
        /// socket as `wss://${gw.address.split(...)}`: `gw` is an OBJECT with an
        /// `address` field — the same shape as a `/v1/streaming/gateways` entry
        /// — NOT a bare string. Declaring it `String` made the whole DTO fail to
        /// decode, so a perfectly good response was read as "not ready" and the
        /// app waited forever. Decoded here from either shape, and optional
        /// because a session that hasn't been assigned a machine yet omits it.
        let gwAddress: String?
        let queryString: String?

        private enum CodingKeys: String, CodingKey { case gw, queryString }

        private struct Gateway: Decodable { let address: String }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            queryString = try? c.decode(String.self, forKey: .queryString)
            if let asString = try? c.decode(String.self, forKey: .gw) {
                gwAddress = asString
            } else if let asObject = try? c.decode(Gateway.self, forKey: .gw) {
                gwAddress = asObject.address
            } else {
                gwAddress = nil
            }
        }
    }
    let data: Payload
}

/// One entry of `GET /api/v1/streaming/gateways` — the per-account gateway
/// list (CONFIRMED 2026-07-24). `priority` marks the ones for the account's
/// own region; `/gateways/applications/{appId}` lists every gateway hosting a
/// given game, which is a wider set.
nonisolated struct BoosteroidGateway {
    let address: String
    let priority: Bool
}

/// CONFIRMED shape of `POST /api/v1/streaming/session/details`'s error body
/// for an expired/timed-out session (HTTP 406) — see SessionInfo doc comment.
nonisolated struct BoosteroidSessionDetailsErrorDTO: Codable {
    struct Payload: Codable {
        let title: String?
        let message: String?
        let icon: String?
        let code: String?
    }
    let data: Payload
}

nonisolated struct ActiveSessionInfo {
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
nonisolated struct BoosteroidApplicationDTO: Codable {
    let id: Int
    let name: String
    let icon: String?
    let bannerImage: String?
    let installed: Bool
}

nonisolated struct BoosteroidPaginatedApplications: Codable {
    let data: [BoosteroidApplicationDTO]
}

nonisolated struct GameInfo: Identifiable, Equatable {
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
nonisolated struct SessionCreateRequest {
    let gameId: String
    let settings: StreamSettings
}
