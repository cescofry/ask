import AppKit
import Foundation

// ---------------------------------------------------------------------------
// Ask WebKit — native macOS app that opens opencode web in a chromeless window
// ---------------------------------------------------------------------------

class AppDelegate: NSObject, NSApplicationDelegate {
    private var server: OpencodeServer?
    private let webWindow = WebWindow()
    private var config: AppConfig!

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Load config
        config = loadConfig()

        // Validate working directory
        var isDir: ObjCBool = false
        if !FileManager.default.fileExists(atPath: config.web.workingDir, isDirectory: &isDir)
            || !isDir.boolValue
        {
            let alert = NSAlert()
            alert.messageText = "Invalid working directory"
            alert.informativeText =
                "The configured working directory does not exist:\n\(config.web.workingDir)\n\nEdit ~/.config/ask/config.yml to fix this."
            alert.alertStyle = .critical
            alert.addButton(withTitle: "Quit")
            alert.runModal()
            NSApp.terminate(nil)
            return
        }

        // Set up server manager
        server = OpencodeServer(config: config)

        // Register global shortcut
        guard let shortcut = parseShortcut(config.shortcut) else {
            let alert = NSAlert()
            alert.messageText = "Invalid shortcut"
            alert.informativeText =
                "Could not parse shortcut: \"\(config.shortcut)\"\n\nEdit ~/.config/ask/config.yml to fix this.\nFormat: ctrl+shift+a"
            alert.alertStyle = .critical
            alert.addButton(withTitle: "Quit")
            alert.runModal()
            NSApp.terminate(nil)
            return
        }

        let registered = registerGlobalHotKey(shortcut: shortcut) { [weak self] in
            self?.handleShortcut()
        }

        if !registered {
            let alert = NSAlert()
            alert.messageText = "Could not register shortcut"
            alert.informativeText =
                "Failed to register global shortcut: \(config.shortcut)\n\nThe shortcut may be in use by another app, or Accessibility permissions may be required.\n\nGo to System Settings > Privacy & Security > Accessibility and add this app."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Continue Anyway")
            alert.addButton(withTitle: "Quit")
            if alert.runModal() == .alertSecondButtonReturn {
                NSApp.terminate(nil)
                return
            }
        }

        NSLog("Ask: running — press %@ to open", config.shortcut)
    }

    func applicationWillTerminate(_ notification: Notification) {
        unregisterGlobalHotKey()
        server?.shutdown()
    }

    // MARK: - Shortcut handler

    private func handleShortcut() {
        // Reload config on each shortcut press so edits take effect without restart
        config = loadConfig()

        guard let server = server else { return }

        // Check if server config changed (port, model, or password)
        let currentServer = OpencodeServer(config: config)
        if server.baseURL != currentServer.baseURL || server.password != currentServer.password {
            // Config changed — switch to new server
            server.shutdown()
            self.server = currentServer
        }

        let srv = self.server!
        let url = srv.projectURL

        // If window is already visible, toggle hide
        if webWindow.isVisible {
            webWindow.hide()
            return
        }

        // Ensure server is running, then show window
        srv.ensureRunning { [weak self] success in
            guard success else {
                let alert = NSAlert()
                alert.messageText = "Server failed to start"
                alert.informativeText =
                    "Could not start opencode server on port \(self?.config.web.port ?? 0).\n\nCheck that opencode is installed and the configured working directory exists."
                alert.alertStyle = .warning
                alert.addButton(withTitle: "OK")
                alert.runModal()
                return
            }
            self?.webWindow.showOrFocus(url: url)
        }
    }
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

let app = NSApplication.shared
app.setActivationPolicy(.regular)  // Visible in Dock and Cmd+Tab

// Build standard menu bar so Cmd+C / Cmd+V / etc. work in the WebView
let mainMenu = NSMenu()

let appMenuItem = NSMenuItem()
mainMenu.addItem(appMenuItem)
let appMenu = NSMenu()
appMenu.addItem(withTitle: "Quit Ask", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
appMenuItem.submenu = appMenu

let editMenuItem = NSMenuItem()
mainMenu.addItem(editMenuItem)
let editMenu = NSMenu(title: "Edit")
editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
editMenu.addItem(NSMenuItem.separator())
editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
editMenuItem.submenu = editMenu

app.mainMenu = mainMenu

let delegate = AppDelegate()
app.delegate = delegate
app.run()
