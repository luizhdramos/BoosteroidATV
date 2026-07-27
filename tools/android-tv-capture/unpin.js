// Minimal, self-contained Java-level SSL-pinning bypass — written in-house
// after the public akabe1/frida-multiple-unpinning CodeShare script crashed
// ("access violation accessing 0x0" inside frida's java.js bridge) on this
// frida-tools version (17.16.4), likely because that script is unmaintained
// and assumes an older Java-bridge API for one of its many hooks and dies
// before installing any of them.
//
// Each hook here is wrapped in its own try/catch, so a missing class (the
// app not using OkHttp, say) just skips that hook instead of aborting
// everything else — the actual bug that made the CodeShare script useless.
Java.perform(function () {
  console.log("[unpin] starting");

  // 1) Blanket bypass: replace the TrustManager used by any SSLContext.init()
  // call with one that accepts everything. This is the broadest hook and
  // alone covers most custom/raw HttpsURLConnection-based networking.
  try {
    var TrustManager = Java.registerClass({
      name: "com.unpin.TrustManager",
      implements: [Java.use("javax.net.ssl.X509TrustManager")],
      methods: {
        checkClientTrusted: function () {},
        checkServerTrusted: function () {},
        getAcceptedIssuers: function () { return []; },
      },
    });
    var TrustManagers = [TrustManager.$new()];
    var SSLContext = Java.use("javax.net.ssl.SSLContext");
    SSLContext.init.overload(
      "[Ljavax.net.ssl.KeyManager;",
      "[Ljavax.net.ssl.TrustManager;",
      "java.security.SecureRandom"
    ).implementation = function (keyManager, trustManager, secureRandom) {
      console.log("[unpin] SSLContext.init() — installing permissive TrustManager");
      this.init(keyManager, TrustManagers, secureRandom);
    };
    console.log("[unpin] hooked SSLContext.init");
  } catch (e) {
    console.log("[unpin] SSLContext hook failed: " + e);
  }

  // 2) OkHttp3's CertificatePinner (the most common Android HTTP pinning
  // mechanism) — both overloads seen across OkHttp versions.
  try {
    var CP = Java.use("okhttp3.CertificatePinner");
    CP.check.overload("java.lang.String", "java.util.List").implementation = function (host, list) {
      console.log("[unpin] OkHttp3 CertificatePinner.check(String, List) bypassed for " + host);
    };
    console.log("[unpin] hooked OkHttp3 CertificatePinner (List overload)");
  } catch (e) {
    console.log("[unpin] OkHttp3 (List) hook failed: " + e);
  }
  try {
    var CP2 = Java.use("okhttp3.CertificatePinner");
    CP2.check.overload("java.lang.String", "[Ljava.security.cert.Certificate;").implementation = function (host, certs) {
      console.log("[unpin] OkHttp3 CertificatePinner.check(String, Certificate[]) bypassed for " + host);
    };
    console.log("[unpin] hooked OkHttp3 CertificatePinner (Certificate[] overload)");
  } catch (e) {
    console.log("[unpin] OkHttp3 (Certificate[]) hook failed: " + e);
  }

  // 3) Android's own TrustManagerImpl.verifyChain — what most default
  // HttpsURLConnection/Conscrypt validation ultimately calls.
  try {
    var TMI = Java.use("com.android.org.conscrypt.TrustManagerImpl");
    TMI.verifyChain.implementation = function (untrustedChain, trustAnchorChain, host, clientAuth, ocspData, tlsSctData) {
      console.log("[unpin] TrustManagerImpl.verifyChain bypassed for " + host);
      return untrustedChain;
    };
    console.log("[unpin] hooked TrustManagerImpl.verifyChain");
  } catch (e) {
    console.log("[unpin] TrustManagerImpl hook failed: " + e);
  }

  // 4) WebView-based clients (in case the login/QR screen is a WebView, as
  // its visual similarity to the web dashboard suggested).
  try {
    var WVC = Java.use("android.webkit.WebViewClient");
    WVC.onReceivedSslError.implementation = function (view, handler, error) {
      console.log("[unpin] WebViewClient.onReceivedSslError bypassed — proceeding anyway");
      handler.proceed();
    };
    console.log("[unpin] hooked WebViewClient.onReceivedSslError");
  } catch (e) {
    console.log("[unpin] WebViewClient hook failed: " + e);
  }

  console.log("[unpin] all hooks attempted — see lines above for which ones actually attached");
});
