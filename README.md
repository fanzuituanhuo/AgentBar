# AgentBar

**原生 macOS 液态玻璃（Liquid Glass）菜单栏 AI Agent 会话监控、指标统计与一键审批工具。**

AgentBar 可从本机 Antigravity 2.0 的会话摘要库读取近期会话。没有可显示的摘要时，如果 Antigravity 正在运行，会话页会显示应用入口。点击条目可打开或切回 Antigravity。本机安装并登录 Antigravity CLI（`agy` 1.1.11 或更新版本）后，「订阅会员 & Dashboard」也会读取 CLI 提供的套餐名称、各模型组额度及重置时间。

## 构建与打包 DMG

```bash
git clone https://github.com/tangziyi1226-lab/AgentBar.git
cd AgentBar
./scripts/build_dmg.sh
```

编译完成后产物位于 `dist/` 目录：
- **应用包**：`dist/AgentBar.app`
- **安装包镜像**：`dist/AgentBar.dmg`

直接安装并启动到菜单栏：

```bash
cp -R dist/AgentBar.app /Applications/
open /Applications/AgentBar.app
```

---

## 项目结构（欢迎自由魔改 🛠️）

代码结构非常轻量清晰，很适合按你自己的工作流继续扩展新 Agent、新指标或自定义 UI：

```text
AgentBar/
├── Package.swift
├── Sources/
│   ├── AgentBarCore/                 # 核心数据模型、解析器与后台服务
│   │   ├── Models.swift              # 会话、状态、主机与分组核心模型
│   │   ├── CodexAdapter.swift        # Codex 桌面版 / CLI 会话与速率解析
│   │   ├── ClaudeCodeAdapter.swift   # Claude Code CLI / IDE 扩展会话解析
│   │   ├── DeepSeekHarnessAdapter.swift
│   │   ├── CursorTraeAdapter.swift   # Cursor / Trae 本地工作区会话解析
│   │   ├── SSHProbeService.swift     # ~/.ssh/config 自动发现与无阻塞并发远程探测
│   │   ├── HookApprovalManager.swift # 一键审批 Hook 管理与高危命令拦截
│   │   ├── BalanceService.swift      # SSO 网页 / JSON API / 脚本额度提取
│   │   └── PricingAndMetrics.swift   # 模型定价估算与上下文窗口目录
│   ├── AgentBarApp/                  # macOS 菜单栏原生 Liquid Glass 界面
│   │   ├── StatusBarController.swift # 菜单栏多色胶囊与无边框透明悬浮面板
│   │   ├── PanelView.swift           # 主面板、流式筛选栏与主机/目录树
│   │   ├── SessionRowView.swift      # 会话卡片、展开遥测详情与 Markdown 预览
│   │   ├── OverviewDashboardView.swift # 总数据看板与订阅额度视图
│   │   └── JumpService.swift         # Codex Deep Link / Remote-SSH IDE / 终端精准跳转
│   └── agentbar-hook/                # 轻量审批事件桥接 CLI
└── scripts/
    └── build_dmg.sh                  # 一键 Release 编译、图标生成、本地签名与 DMG 打包脚本
```

## 隐私说明

- **纯本地运行**：AgentBar 所有会话读取、SSH 探测与统计均在你的 Mac 本机完成，不会向任何第三方服务器上传任何对话内容、路径或密钥。
- **凭证安全存储**：API Token 存储在系统钥匙串（macOS Keychain），SSO 登录态仅保存在本机 `WKWebsiteDataStore` 中。

---

如果觉得有用欢迎点个 Star ⭐，也欢迎 Fork 出去按自己的习惯改造新功能！
