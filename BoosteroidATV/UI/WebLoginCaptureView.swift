import SwiftUI
import WebKit

/// Embedded web login pointed at https://cloud.boosteroid.com/auth/start.
///
/// CONFIRMED 2026-07-22: a successful login DOES navigate to a distinct URL —
/// away from /auth/login and /auth/start entirely, over to /dashboard. That's
/// a reliable, confirmable success signal (unlike when this comment was
/// written) — TODO(protocol): wire up automatic detection by watching
/// `webView.url?.path == "/dashboard"` (or more robustly, no longer starting
/// with "/auth") in `webView(_:didFinish:)`, instead of relying on the manual
/// "I'm signed in" button below. Also confirmed: the login form is gated by a
/// Cloudflare Turnstile challenge that must render and be solved by the user
/// inside the web view before the email/password fields become usable — make
/// sure the WKWebView doesn't set a custom (e.g. mobile/TV) user agent that
/// could cause Turnstile to behave unexpectedly.
///
/// Session state is cookie-based (confirmed: GET /api/v1/user succeeds after
/// login with no bearer token visible anywhere) — capturing cookies here, as
/// this view already does, is the right approach; just needs the automatic
/// trigger described above instead of a manual button.
struct WebLoginCaptureView: UIViewControllerRepresentable {
    let startURL: URL
    /// Bump this value (e.g. from a "I'm signed in" button) to trigger a cookie capture.
    var captureTrigger: Int = 0
    let onCurrentURLChanged: (URL) -> Void
    let onCapture: ([String: String]) -> Void

    func makeUIViewController(context: Context) -> UIViewController {
        let vc = UIViewController()
        let webView = WKWebView(frame: .zero)
        webView.navigationDelegate = context.coordinator
        webView.translatesAutoresizingMaskIntoConstraints = false
        vc.view.backgroundColor = .black
        vc.view.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: vc.view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: vc.view.trailingAnchor),
            webView.topAnchor.constraint(equalTo: vc.view.topAnchor),
            webView.bottomAnchor.constraint(equalTo: vc.view.bottomAnchor),
        ])
        context.coordinator.webView = webView
        webView.load(URLRequest(url: startURL))
        return vc
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        guard context.coordinator.lastCaptureTrigger != captureTrigger else { return }
        context.coordinator.lastCaptureTrigger = captureTrigger
        context.coordinator.captureCookies()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onCurrentURLChanged: onCurrentURLChanged, onCapture: onCapture)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        private let onCurrentURLChanged: (URL) -> Void
        private let onCapture: ([String: String]) -> Void
        weak var webView: WKWebView?
        var lastCaptureTrigger: Int = 0
        private var autoCaptured = false

        init(onCurrentURLChanged: @escaping (URL) -> Void, onCapture: @escaping ([String: String]) -> Void) {
            self.onCurrentURLChanged = onCurrentURLChanged
            self.onCapture = onCapture
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard let url = webView.url else { return }
            onCurrentURLChanged(url)
            // CONFIRMED signal: a successful login lands on /dashboard (no
            // longer under /auth/...). Auto-capture the first time we see it,
            // instead of waiting for the manual "I'm signed in" button.
            if !autoCaptured, !url.path.hasPrefix("/auth") {
                autoCaptured = true
                captureCookies()
            }
        }

        /// Reads all cookies visible to the web view's data store right now.
        /// Called by LoginView's manual "I'm signed in" button.
        func captureCookies() {
            webView?.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                var dict: [String: String] = [:]
                for cookie in cookies where cookie.domain.contains("boosteroid") {
                    dict[cookie.name] = cookie.value
                }
                self.onCapture(dict)
            }
        }
    }
}
