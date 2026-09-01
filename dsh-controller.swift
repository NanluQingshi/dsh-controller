/**
 * DSH Controller — macOS menu-bar controller for the `dsh web` server.
 *
 * A resident status-bar item (the dsh whale + status dot) showing whether
 * the dsh web GUI is up, with menu actions to start it detached (logs to
 * ~/Library/Logs), terminate it (TERM, escalating to KILL), open the UI,
 * and toggle launch-at-login.
 *
 * Configuration (UserDefaults, domain local.dsh.controller):
 *   dshPath — absolute path of the dsh launcher (default: auto-detected
 *             once via an interactive login shell, i.e. nvm-aware)
 *   port    — GUI port (default 3080)
 *
 * Single-file AppKit app, compiled with:
 *   swiftc -O -o DSHController dsh-controller.swift
 */

import Cocoa
import ServiceManagement

// MARK: - Configuration

/// User overrides: `defaults write local.dsh.controller dshPath /path/to/dsh`
/// and `... port 8080`. Unset values fall back to auto-detection / 3080.
let defaults = UserDefaults.standard
/// Path of the dsh launcher. UserDefaults override wins; otherwise detected
/// once at launch via an interactive login shell (picks up nvm/etc.).
var dshPath: String? = defaults.string(forKey: "dshPath").flatMap { $0.isEmpty ? nil : $0 }
/// The port the web GUI serves on (UserDefaults "port", default 3080).
let dshPort: Int = (defaults.object(forKey: "port") as? Int) ?? 3080
/// Where the detached server's output goes.
let logPath = NSHomeDirectory() + "/Library/Logs/dsh-web.log"
/// The web GUI base URL (status probe target and "open" target).
let dshURL = URL(string: "http://127.0.0.1:\(dshPort)/")!
/**
 * Stop command: signal whoever LISTENS on the GUI port. Port-based lookup
 * (lsof) is used instead of `pkill -f` because pattern matching against the
 * server's argv proved unreliable (pgrep/pkill could not see the process
 * arguments of the running `dsh web` on the reference machine).
 */
let stopCommand = "pids=$(lsof -tiTCP:\(dshPort) -sTCP:LISTEN); [ -n \"$pids\" ] && kill %@ $pids"

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

	private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
	/** Menu-bar glyph: the dsh whale as a template image (theme-adaptive). */
	private let whaleImage: NSImage? = {
		guard let image = Bundle.main.image(forResource: "menubar-whale") else { return nil }
		image.isTemplate = true
		image.size = NSSize(width: 18, height: 18)
		return image
	}()
	private let menu = NSMenu()
	private let statusLine = NSMenuItem(title: "检查中…", action: nil, keyEquivalent: "")
	private let startItem = NSMenuItem(title: "启动 dsh", action: #selector(startDsh), keyEquivalent: "")
	private let stopItem = NSMenuItem(title: "终止 dsh", action: #selector(stopDsh), keyEquivalent: "")
	private let openItem = NSMenuItem(title: "打开 Web 界面", action: #selector(openUI), keyEquivalent: "")
	private let loginItem = NSMenuItem(title: "开机自启动", action: #selector(toggleLogin), keyEquivalent: "")

	/// nil while a probe is in flight or a start/stop is settling.
	private var running: Bool?
	/// True between a start/stop action and the port settling.
	private var transitioning = false
	/// What kind of transition is in flight ("start" / "stop"), for labels.
	private var transitionKind: String?
	/// Remaining fast polls while waiting for the port to settle.
	private var settleTicks = 0
	private var pollTimer: Timer?

	func applicationDidFinishLaunching(_ notification: Notification) {
		startItem.target = self
		stopItem.target = self
		openItem.target = self
		loginItem.target = self

		menu.addItem(statusLine)
		menu.addItem(.separator())
		menu.addItem(startItem)
		menu.addItem(stopItem)
		menu.addItem(openItem)
		menu.addItem(.separator())
		menu.addItem(loginItem)
		menu.addItem(.separator())
		menu.addItem(NSMenuItem(title: "退出控制器", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
		menu.delegate = self
		menu.autoenablesItems = false

		statusItem.button?.toolTip = "DSH Controller"
		statusItem.menu = menu
		render()
		poll()
		detectDshPath()

		pollTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
			self?.poll()
		}
	}

	/// Find `dsh` once via an interactive login shell (loads .zshrc → nvm).
	private func detectDshPath() {
		guard dshPath == nil else { return }
		let process = Process()
		process.executableURL = URL(fileURLWithPath: "/bin/zsh")
		process.arguments = ["-ic", "command -v dsh"]
		let pipe = Pipe()
		process.standardOutput = pipe
		process.standardError = FileHandle.nullDevice
		do {
			try process.run()
		} catch {
			return
		}
		DispatchQueue.global().async { [weak self] in
			process.waitUntilExit()
			let data = pipe.fileHandleForReading.readDataToEndOfFile()
			let output = String(data: data, encoding: .utf8)?
				.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
			DispatchQueue.main.async { [weak self] in
				guard let self = self else { return }
				if output.hasPrefix("/") {
					dshPath = output
					self.render()
				}
			}
		}
	}

	// MARK: Status probing

	/// Probe the GUI port; HTTP any-response ⇒ running.
	private func poll() {
		var request = URLRequest(url: dshURL)
		request.timeoutInterval = 2
		URLSession.shared.dataTask(with: request) { [weak self] _, response, error in
			let alive = error == nil && (response as? HTTPURLResponse) != nil
			DispatchQueue.main.async { self?.settle(alive: alive) }
		}.resume()
	}

	/// Apply a probe result; while transitioning keep fast-polling for a bit.
	private func settle(alive: Bool) {
		if transitioning {
			settleTicks -= 1
			if settleTicks > 0 {
				scheduleProbe(after: 1)
				return
			}
			transitioning = false
			transitionKind = nil
		}
		running = alive
		render()
	}

	/// One delayed probe (used by the settle fast-poll loop).
	private func scheduleProbe(after seconds: TimeInterval) {
		DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
			self?.poll()
		}
	}

	// MARK: Actions

	@objc private func startDsh() {
		guard !transitioning, let bin = dshPath else { return }
		transitioning = true
		transitionKind = "start"
		settleTicks = 20 // up to ~20 s of 1 s polls for the port to come up
		running = nil
		render()
		let script = "nohup '\(bin)' web >> '\(logPath)' 2>&1 &"
		runZsh(script)
		scheduleProbe(after: 1)
	}

	@objc private func stopDsh() {
		guard !transitioning else { return }
		transitioning = true
		transitionKind = "stop"
		settleTicks = 8 // ~8 s for TERM, then KILL below
		running = nil
		render()
		runZsh(String(format: stopCommand, "-TERM"))
		scheduleProbe(after: 1)
		// Escalation: if the port is still up after 5 s, force-kill.
		DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
			guard let self = self, self.transitioning else { return }
			self.runZsh(String(format: stopCommand, "-KILL"))
		}
	}

	@objc private func openUI() {
		// Async: the AppleScript scan can block on a TCC permission prompt —
		// never let that freeze the menu bar. Connection-based activation
		// runs first (fast, reliable); AppleScript then refines to the
		// exact tab when the browser is scriptable-reachable.
		DispatchQueue.global(qos: .userInitiated).async { [self] in
			autoreleasepool {
				let connected = activateGuiBrowserByConnection()
				var asHit = false
				for browser in orderedScriptableBrowsers() where !asHit {
					asHit = runFocusScript(browser)
				}
				log("openUI: connectedActivation=\(connected) appleScriptTab=\(asHit)")
				if !connected && !asHit {
					DispatchQueue.main.async { NSWorkspace.shared.open(dshURL) }
				}
			}
		}
	}

	// MARK: Existing-tab focus

	/**
	 * Scriptable browsers we know how to focus a tab in.
	 */
	private static let scriptableBrowsers: [(bundleID: String, appName: String, safari: Bool)] = [
		("com.google.Chrome", "Google Chrome", false),
		("com.microsoft.edgemac", "Microsoft Edge", false),
		("com.brave.Browser", "Brave Browser", false),
		("org.chromium.Chromium", "Chromium", false),
		("com.apple.Safari", "Safari", true),
	]

	/// Running scriptable browsers, default browser first.
	private func orderedScriptableBrowsers() -> [(bundleID: String, appName: String, safari: Bool)] {
		let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
		var order = Self.scriptableBrowsers.filter { running.contains($0.bundleID) }
		if let defaultBrowser = NSWorkspace.shared.urlForApplication(toOpen: dshURL)
			.flatMap({ Bundle(url: $0)?.bundleIdentifier })
			.flatMap({ id in Self.scriptableBrowsers.first(where: { $0.bundleID == id }) }) {
			order.removeAll { $0.bundleID == defaultBrowser.bundleID }
			order.insert(defaultBrowser, at: 0)
		}
		return order
	}

	/// URL prefixes that count as "the GUI is already open in a tab".
	private var guiURLPrefixes: [String] {
		["http://127.0.0.1:\(dshPort)/", "http://localhost:\(dshPort)/"]
	}

	private func log(_ message: String) {
		let line = "\(Date.now.formatted()) \(message)\n"
		let path = NSHomeDirectory() + "/Library/Logs/dsh-controller.log"
		if let handle = FileHandle(forWritingAtPath: path) {
			defer { try? handle.close() }
			handle.seekToEndOfFile()
			handle.write(line.data(using: .utf8) ?? Data())
		} else {
			try? line.write(toFile: path, atomically: true, encoding: .utf8)
		}
	}

	/**
	 * Activate the browser that actually holds live GUI connections — found
	 * via the socket, immune to automation-Chrome instance mixups that make
	 * the real browser invisible to AppleScript. Returns true when a browser
	 * was activated.
	 */
	private func activateGuiBrowserByConnection() -> Bool {
		guard let listenerPID = firstPID("lsof -tiTCP:\(dshPort) -sTCP:LISTEN") else {
			log("connectionActivation: no listener on port \(dshPort)")
			return false
		}
		let selfPID = ProcessInfo.processInfo.processIdentifier
		for pid in pids("lsof -tiTCP:\(dshPort) -sTCP:ESTABLISHED") where pid != selfPID && pid != listenerPID {
			if let app = owningApplication(of: pid) {
				let ok = app.activate()
				log("connectionActivation: pid \(pid) -> \(app.localizedName ?? app.bundleIdentifier ?? "?") activate=\(ok)")
				return ok
			}
		}
		log("connectionActivation: no non-self GUI client found")
		return false
	}

	private func pids(_ command: String) -> [pid_t] {
		(runZshCapture(command) ?? "")
			.split(whereSeparator: \.isWhitespace)
			.compactMap { pid_t($0) }
	}

	private func runZshCapture(_ script: String) -> String? {
		let process = Process()
		process.executableURL = URL(fileURLWithPath: "/bin/zsh")
		process.arguments = ["-c", script]
		let pipe = Pipe()
		process.standardOutput = pipe
		process.standardError = FileHandle.nullDevice
		do { try process.run() } catch { return nil }
		process.waitUntilExit()
		guard process.terminationStatus == 0 else { return nil }
		return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
	}

	private func firstPID(_ command: String) -> pid_t? {
		pids(command).first
	}

	/// Walk up the process tree from a helper PID (e.g. Chrome's network
	/// service) to the registered regular .app that owns it.
	private func owningApplication(of pid: pid_t) -> NSRunningApplication? {
		var current = pid
		for _ in 0..<12 {
			if let app = NSRunningApplication(processIdentifier: current),
				app.activationPolicy == .regular {
				return app
			}
			guard let parent = pids("ps -o ppid= -p \(current)").first, parent > 1 else { return nil }
			current = parent
		}
		return nil
	}

	/**
	 * AppleScript: activate the browser and focus the first tab whose URL
	 * matches the GUI. Returns true on a hit; false on miss or error
	 * (automation permission denied, browser busy) — the caller then falls
	 * back to opening a fresh tab.
	 */
	private func runFocusScript(_ browser: (bundleID: String, appName: String, safari: Bool)) -> Bool {
		let condition = guiURLPrefixes
			.map { "URL of t starts with \"\($0)\"" }
			.joined(separator: " or ")
		let focusCommand = browser.safari
			? "set current tab of w to t"
			: "set active tab index of w to (index of t)"
		let source = """
			tell application "\(browser.appName)"
				repeat with w in windows
					repeat with t in (tabs of w)
						if \(condition) then
							\(focusCommand)
							set index of w to 1
							activate
							return "true"
						end if
					end repeat
				end repeat
			end tell
			return "false"
			"""
		var error: NSDictionary?
		let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
		return error == nil && result?.stringValue == "true"
	}

	@objc private func toggleLogin() {
		if SMAppService.mainApp.status == .enabled {
			try? SMAppService.mainApp.unregister()
		} else {
			try? SMAppService.mainApp.register()
		}
		renderLoginState()
	}

	// MARK: Rendering

	private func render() {
		let dotColor: NSColor
		var statusText: String
		switch running {
		case .some(true):
			dotColor = .systemGreen
			statusText = "dsh 运行中 · 127.0.0.1:\(dshPort)"
		case .some(false):
			dotColor = .systemGray
			statusText = "dsh 已停止"
		case .none:
			dotColor = .systemYellow
			switch transitionKind {
			case "start": statusText = "正在启动…"
			case "stop": statusText = "正在终止…"
			default: statusText = "检查中…"
			}
		}
		if dshPath == nil && running != true { statusText += "（未检测到 dsh 路径）" }
		if let button = statusItem.button {
			button.image = whaleImage
			let label = whaleImage != nil ? "●" : "dsh ●"
			let title = NSMutableAttributedString(string: label)
			title.addAttribute(.foregroundColor, value: dotColor,
				range: NSRange(location: label.count - 1, length: 1))
			button.attributedTitle = title
		}
		statusLine.title = statusText
		startItem.isEnabled = !transitioning && running == false && dshPath != nil
		stopItem.isEnabled = !transitioning && running == true
		openItem.isEnabled = running == true
		renderLoginState()
	}

	private func renderLoginState() {
		loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
	}

	// MARK: NSMenuDelegate

	func menuWillOpen(_ menu: NSMenu) {
		if !transitioning { poll() }
		renderLoginState()
	}

	// MARK: Process helper

	/// Run a zsh snippet; fire-and-forget. PATH gets the dsh launcher's own
	/// bin dir prepended (the launcher is a node script needing `node`).
	private func runZsh(_ script: String) {
		let process = Process()
		process.executableURL = URL(fileURLWithPath: "/bin/zsh")
		var environment = ProcessInfo.processInfo.environment
		if let dir = dshPath.map({ ($0 as NSString).deletingLastPathComponent }), !dir.isEmpty {
			environment["PATH"] = dir + ":" + (environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
		}
		process.environment = environment
		process.arguments = ["-c", script]
		try? process.run()
	}
}

// MARK: - Bootstrap

let delegate = AppDelegate()
let application = NSApplication.shared
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
