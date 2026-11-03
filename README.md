# Ferret

一个 macOS 小工具（名字取自雪貂：天生在隧道里穿行）：用 **launchd 常驻 SSH 反向隧道**，把远程服务器的模型网关（magpie `3425`）和出网代理（`58922`）转发回本机；并提供一个图形界面管理多台服务器、查看连接历史、监测远端代理分流。

## 组件

| 组件 | 说明 |
| --- | --- |
| `app/` | Swift + AppKit 图形界面（`Ferret.app`） |
| `scripts/resident.sh` | 管理每台服务器一个的 launchd 常驻隧道（`local.remotetunnel.tunnel-<host>`） |
| `scripts/tunnel-resident.sh` | 常驻 ssh 进程本体（断线重连） |
| `scripts/routing-report.sh` | 在远端生成"代理分流报告"（OpenAI 走隧道 / 其余直连） |

## 工作原理

```
[本机]                                  [远程服务器]
magpie 3425  ◀── RemoteForward 3425 ── 127.0.0.1:3425（模型网关 / MCP）
Clash 7897   ◀── RemoteForward 58922 ─ 127.0.0.1:58922（mihomo 的上游代理）
                              mihomo 7890（服务器本地规则代理）
                                ├ OpenAI/chatgpt 域名 → 58922 → 本机 Clash
                                └ 其余 → 服务器直连
```

常驻 ssh 由 launchd 的 `KeepAlive` 守护；服务器 sshd 建议开启
`ClientAliveInterval 15` / `ClientAliveCountMax 3`，这样断网后的旧会话会在约 45 秒内被回收、释放转发端口。

## 使用

### 1. 构建与安装

```bash
cd app
./scripts/build.sh      # 生成 build/Ferret.app
./scripts/install.sh    # 安装到 /Applications
```

### 2. 在界面里添加服务器

填：显示名、隧道 Host（本机 `~/.ssh/config` 里新建的别名）、探测 Host（登录服务器用的别名）、
以及 SSH 主机名 / 端口 / 用户名 / 私钥、两个远端端口和本机 magpie、Clash 端口。

「保存并重启」会：

1. 在 `~/.ssh/config` 写入带标记的 Host 段（`RemoteForward` 两条）；
2. 为目标 Host 创建/重启 launchd 常驻隧道。

### 3. 命令行管理（可选）

```bash
./scripts/resident.sh install my-tunnel   # 安装并启动
./scripts/resident.sh status  my-tunnel
./scripts/resident.sh stop    my-tunnel
./scripts/routing-report.sh   my-server   # 远端分流报告
```

### 4. 新服务器初始化（内置说明 + 依赖检查）

「服务器初始化说明」标签页内置一段可复制的任务说明（目标、步骤、验收、约束、回滚，STC 风格），
会自动带上当前服务器的探测 Host 与远端端口；点「复制给 agent」后可整段粘贴给任意 agent 去配置服务器。
「检查服务器依赖」会 ssh 到该服务器检查 codex / mihomo / network.env / 模型接口 / OpenAI / GitHub / base_url / sshd keepalive。

### 5. 日志与连接历史

界面上的启动/停止/切换/检测等操作会写入 `log/history.log`；界面可「查看历史」「清空历史」。

## 服务器端前置条件

- 能免密 SSH 登录，且 `~/.ssh/config` 有对应别名；
- 远程 `127.0.0.1:3425` 提供 magpie 网关（模型 `/v1`、MCP `/mcp`）；
- 远程 `127.0.0.1:58922` 是 mihomo 的上游，mihomo 监听 `127.0.0.1:7890` 并按域名分流；
- 建议 sshd 开启 `ClientAliveInterval`，避免旧会话占着转发端口。

## 许可

自用脚本，按需修改。

仓库：https://github.com/baiseraku/ferret
