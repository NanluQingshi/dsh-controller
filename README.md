# DSH Controller

A macOS menu-bar controller for the [DSH](https://www.npmjs.com/package/@deepseek-ai/dsh)
web server — start and stop `dsh web` with one click, no terminal required.

## Features

A resident status-bar item — the DSH whale plus a status dot
(🟢 running · ⚪ stopped · 🟡 switching) — with a menu that offers:

| Menu item | Action |
|---|---|
| 启动 dsh (Start) | Launches `dsh web` detached (`nohup`, logs to `~/Library/Logs/dsh-web.log`) |
| 终止 dsh (Stop) | SIGTERMs the process listening on the GUI port, escalating to SIGKILL after 5 s |
| 打开 Web 界面 (Open UI) | Opens the GUI in your default browser |
| 开机自启动 (Launch at login) | Registers/unregisters the login item (`SMAppService`) |
| 退出控制器 (Quit) | Quits the controller itself (the dsh server keeps running) |

Status is probed every 3 s (and refreshed the moment the menu opens).

## Build

Requirements: macOS 13+, Xcode Command Line Tools (`swiftc`).

```zsh
./build.sh                          # build, install to /Applications, relaunch
./build.sh ~/Apps/DSH\ Controller.app   # custom install location
```

Regenerate the icons after editing `Assets/whale.svg`:

```zsh
swift scripts/make-icon.swift
```

## Configuration

Defaults domain `local.dsh.controller`:

```zsh
# Absolute path of the dsh launcher (default: auto-detected once via an
# interactive login shell, so nvm-installed dsh is found automatically).
defaults write local.dsh.controller dshPath /usr/local/bin/dsh

# GUI port (default 3080).
defaults write local.dsh.controller port 8080
```

## Design notes

- **Single-file AppKit** (`dsh-controller.swift`, ~270 lines), no third-party
  dependencies, `LSUIElement` so it stays out of the Dock.
- **Stop is port-based** (`lsof -tiTCP:<port> -sTCP:LISTEN`), not
  `pkill -f`: pattern-matching the server's argv proved unreliable on the
  reference machine, while lsof always finds the actual listener.
- **Start injects PATH**: GUI-launched processes have no shell environment,
  so the launcher's own bin dir (nvm's, next to `node`) is prepended.

## Credits

- The whale glyph (`Assets/whale.svg`) comes from
  [`@deepseek-ai/dsh`](https://www.npmjs.com/package/@deepseek-ai/dsh)
  (MIT license).

## License

[MIT](LICENSE) © nlqs
