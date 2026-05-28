import AppKit
import WebKit

// ---------------------------------------------------------------------------
// Chromeless window hosting a WKWebView for the opencode web UI
// ---------------------------------------------------------------------------

class WebWindow: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var webView: WKWebView?

    /// Show (or focus) the chromeless web window, loading the given URL.
    func showOrFocus(url: URL) {
        if let w = window {
            // Window already exists — reload if URL changed, then focus
            if webView?.url != url {
                webView?.load(URLRequest(url: url))
            }
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        // Build WKWebView
        let config = WKWebViewConfiguration()
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.autoresizingMask = [.width, .height]
        self.webView = wv

        // Determine initial window frame — centered, 80% of screen
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let screenFrame = screen.visibleFrame
        let width = screenFrame.width * 0.8
        let height = screenFrame.height * 0.85
        let x = screenFrame.origin.x + (screenFrame.width - width) / 2
        let y = screenFrame.origin.y + (screenFrame.height - height) / 2
        let frame = NSRect(x: x, y: y, width: width, height: height)

        // Chromeless window: titled (for drag) + closable + resizable + miniaturizable,
        // but with the titlebar transparent and content extending into it,
        // giving a borderless look while keeping standard window controls.
        let w = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true
        w.backgroundColor = NSColor(white: 0.08, alpha: 1.0)
        w.minSize = NSSize(width: 400, height: 300)
        w.delegate = self

        // Restore saved frame or use default
        w.setFrameAutosaveName("AskMainWindow")

        wv.frame = w.contentView!.bounds
        w.contentView?.addSubview(wv)

        // Load the opencode web UI
        wv.load(URLRequest(url: url))

        // Monitor for Escape key to hide
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 0x35 {  // Escape
                self?.hide()
                return nil
            }
            return event
        }

        self.window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Hide the window without destroying it.
    func hide() {
        window?.orderOut(nil)
    }

    /// Toggle between show and hide.
    func toggle(url: URL) {
        if let w = window, w.isVisible {
            hide()
        } else {
            showOrFocus(url: url)
        }
    }

    /// Whether the window currently exists and is visible.
    var isVisible: Bool {
        window?.isVisible ?? false
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        // Don't destroy — just hide, so the next shortcut press reopens instantly
        window?.orderOut(nil)
    }
}
