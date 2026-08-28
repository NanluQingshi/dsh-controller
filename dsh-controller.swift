/**
 * DSH Controller — macOS menu-bar controller for the `dsh web` server.
 *
 * A resident status-bar item showing whether the dsh web GUI (port 3080) is
 * up, with menu actions to start it detached (logs to ~/Library/Logs),
 * terminate it (TERM, escalating to KILL), open the UI, and toggle
 * launch-at-login. Single-file AppKit app, compiled with:
 *   swiftc -O -o DSHController dsh-controller.swift
 */

import Cocoa
import ServiceManagement

// MARK: - Constants

/// Absolute path of the dsh launcher (node script).
let dshBin = "/Users/nlqs/.nvm/versions/node/v22.22.2/bin/dsh"
/// The nvm node bin dir the launcher needs on PATH.
let nodeBin = "/Users/nlqs/.nvm/versions/node/v22.22.2/bin"
/// Where the detached server's output goes.
let logPath = "/Users/nlqs/Library/Logs/dsh-web.log"
/// The port the web GUI serves on.
let dshPort = 3080
/// The web GUI base URL (status probe target and "open" target).
let dshURL = URL(string: "http://127.0.0.1:\(dshPort)/")!
/**
 * Stop command: signal whoever LISTENS on the GUI port. Port-based lookup
 * (lsof) is used instead of `pkill -f` because pattern matching against the
 * server's argv proved unreliable (pgrep/pkill could not see the process
 * arguments of the running `dsh web` on this machine).
 */
let stopCommand = "pids=$(lsof -tiTCP:\(dshPort) -sTCP:LISTEN); [ -n \"$pids\" ] && kill %@ $pids"

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

	private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
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

		pollTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
			self?.poll()
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
		guard !transitioning else { return }
		transitioning = true
		transitionKind = "start"
		settleTicks = 20 // up to ~20 s of 1 s polls for the port to come up
		running = nil
		render()
		let script = "nohup '\(dshBin)' web >> '\(logPath)' 2>&1 &"
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
		NSWorkspace.shared.open(dshURL)
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
		let statusText: String
		switch running {
		case .some(true):
			dotColor = .systemGreen
			statusText = "dsh 运行中 · 127.0.0.1:3080"
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
		if let button = statusItem.button {
			let title = NSMutableAttributedString(string: "dsh ●")
			title.addAttribute(.foregroundColor, value: dotColor, range: NSRange(location: 4, length: 1))
			button.attributedTitle = title
		}
		statusLine.title = statusText
		startItem.isEnabled = !transitioning && running == false
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

	/// Run a zsh snippet with the nvm node dir on PATH; fire-and-forget.
	private func runZsh(_ script: String) {
		let process = Process()
		process.executableURL = URL(fileURLWithPath: "/bin/zsh")
		var environment = ProcessInfo.processInfo.environment
		environment["PATH"] = nodeBin + ":" + (environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
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
