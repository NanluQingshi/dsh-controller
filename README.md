# DSH Controller

macOS 菜单栏小控件，一键启动 / 终止 DSH Web 服务，不用再开终端敲命令。

## 功能

菜单栏常驻 `dsh ●` 图标（绿=运行中，灰=已停止，黄=切换中），点击弹出菜单：

| 菜单项 | 说明 |
|---|---|
| 启动 dsh | 后台启动 `dsh web`（nohup 分离进程，日志写入 `~/Library/Logs/dsh-web.log`） |
| 终止 dsh | 向监听 3080 端口的进程发 SIGTERM，5 秒未退自动升级 SIGKILL |
| 打开 Web 界面 | 打开浏览器访问 `http://127.0.0.1:3080` |
| 开机自启动 | 注册 / 取消登录项（SMAppService） |
| 退出控制器 | 退出菜单栏控件本身（不影响 dsh 服务） |

状态每 3 秒探测一次端口；打开菜单时也会立即刷新。

## 构建

依赖：Xcode Command Line Tools（`swiftc`）。

```zsh
./build.sh            # 编译 + 安装到 /Applications 并重启
./build.sh ~/Apps/DSH\ Controller.app   # 自定义安装位置
```

## 设计说明

- **单文件 AppKit**（`dsh-controller.swift`，约 220 行），无第三方依赖，`LSUIElement` 不占 Dock。
- **终止用 lsof 按端口定位**而非 `pkill -f`：实测本机 pgrep/pkill 匹配不到 `dsh web`
  进程的 argv，而 `lsof -tiTCP:3080 -sTCP:LISTEN` 始终准确。
- **启动带完整 PATH**：Finder 启动的 GUI 进程没有 nvm 环境，脚本显式注入 node bin 目录。
- 若 dsh 装到别的 node 版本 / 端口，改源码顶部常量（`dshBin` / `nodeBin` / `dshPort`）后重新构建。
