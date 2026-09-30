package com.appnivo.runtime

import android.annotation.SuppressLint
import android.graphics.Color
import android.os.Bundle
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.activity.OnBackPressedCallback
import androidx.appcompat.app.AppCompatActivity

/**
 * Minimal WebView host for the packaged site (blueprint §9.5).
 *
 * The user's HTML/CSS/JS is injected into `app/src/main/assets` at build time and
 * loaded from `file:///android_asset/index.html`. JavaScript and DOM storage are
 * enabled; there is no network fetch beyond whatever the user's own HTML does.
 */
class MainActivity : AppCompatActivity() {

    private lateinit var webView: WebView

    @SuppressLint("SetJavaScriptEnabled")
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        webView = WebView(this)
        webView.setBackgroundColor(Color.BLACK)
        webView.settings.apply {
            javaScriptEnabled = true
            domStorageEnabled = true
            allowFileAccess = true
            allowContentAccess = true
            cacheMode = WebSettings.LOAD_DEFAULT
            mediaPlaybackRequiresUserGesture = false
        }
        webView.webViewClient = object : WebViewClient() {
            override fun onReceivedError(
                view: WebView,
                request: WebResourceRequest,
                error: WebResourceError,
            ) {
                // Only replace the main document; sub-resource failures are left
                // to the page itself. Inline fallback avoids shipping an asset
                // that the build-time asset copy would overwrite.
                if (request.isForMainFrame) {
                    view.loadDataWithBaseURL(
                        "file:///android_asset/",
                        FALLBACK_HTML,
                        "text/html",
                        "utf-8",
                        null,
                    )
                }
            }
        }

        setContentView(webView)
        webView.loadUrl("file:///android_asset/index.html")

        onBackPressedDispatcher.addCallback(
            this,
            object : OnBackPressedCallback(true) {
                override fun handleOnBackPressed() {
                    if (webView.canGoBack()) webView.goBack() else finish()
                }
            },
        )
    }

    companion object {
        private val FALLBACK_HTML =
            """
            <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">
            <style>html,body{height:100%;margin:0;background:#000;color:#fff;
            font-family:system-ui,sans-serif;display:flex;align-items:center;justify-content:center;text-align:center}
            </style></head><body><div><h1>Offline</h1>
            <p>The app content could not be loaded.</p></div></body></html>
            """.trimIndent()
    }
}
