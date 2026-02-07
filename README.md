# Copilot API Manager

[![Upstream Project](https://img.shields.io/badge/upstream-copilot--api-blue)](https://github.com/nicepkg/copilot-api)

一个管理工具，允许您通过 GitHub Copilot 订阅代理 Claude Code 请求，从而无需单独的 Anthropic API 密钥。

## 🚀 功能特点

- **服务管理**：一键启动/停止 `copilot-api` 服务。
- **动态模型获取**：从 API 实时获取模型列表，而非硬编码。
- **三步模型选择**：
  - Opus (强力型)
  - Sonnet (主流型)
  - Haiku (快速型)
- **厂商分组**：模型按厂商排序：Anthropic → OpenAI → Google → 其他。
- **自动环境配置**：为 Claude Code 自动配置必要的环境变量。
- **守护进程 (Watchdog)**：每 10 秒自动健康检查，失败自动重启（5 分钟内最多重启 5 次）。
- **配置联动**：环境变量修改后自动重启服务。
- **跨平台支持**：支持 macOS/Linux (`.sh`) 和 Windows (`.ps1`)。

## 📋 前提条件

- **Node.js**：用于通过 `npx` 运行 `copilot-api`。
- **GitHub Copilot 订阅**：个人版或商业版。
- **Python 3**：仅 macOS/Linux 脚本需要（用于 JSON 模型解析）。
- **Shell 环境**：
  - macOS/Linux: `zsh`
  - Windows: PowerShell 5.1+

## ⚡ 快速开始

### macOS / Linux
```bash
chmod +x copilot-manager.sh
./copilot-manager.sh
# 选择选项 6 进行一键设置
```

### Windows
```powershell
# 可能需要先设置执行策略
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
.\copilot-manager.ps1
# 选择选项 6 进行一键设置
```

## 🛠️ 菜单选项

| 选项 | 描述 |
|:---:|---|
| 1 | 启动服务 (同时启动守护进程) |
| 2 | 停止服务 |
| 3 | 检查服务状态 |
| 4 | 配置环境变量 |
| 5 | 移除环境变量 |
| 6 | 一键设置并启动 (推荐首次使用) |
| 0 | 退出 |

## 🤖 模型选择

脚本采用三步选择流程，分别为 Claude Code 的不同场景配置模型：
1. **Opus 模型** → 设置 `ANTHROPIC_DEFAULT_OPUS_MODEL` (Claude Code 用于处理复杂任务)。
2. **Sonnet 模型** → 设置 `ANTHROPIC_MODEL` 和 `ANTHROPIC_DEFAULT_SONNET_MODEL` (大部分任务的主力模型)。
3. **Haiku 模型** → 设置 `ANTHROPIC_SMALL_FAST_MODEL` 和 `ANTHROPIC_DEFAULT_HAIKU_MODEL` (用于简单任务的快速模型)。

模型是从正在运行的服务的 `http://localhost:4141/v1/models` 接口实时获取的，过滤掉了过时或内部模型，并按厂商进行了分组显示。

## 🌐 环境变量

脚本会自动设置以下环境变量：

| 变量名 | 描述 | 示例值 |
|---|---|---|
| `ANTHROPIC_BASE_URL` | 代理服务基础地址 | `http://localhost:4141` |
| `ANTHROPIC_MODEL` | 主模型 (Sonnet) | `claude-sonnet-4-20250514` |
| `ANTHROPIC_DEFAULT_OPUS_MODEL` | Opus 模型 | `claude-opus-4-20250514` |
| `ANTHROPIC_DEFAULT_SONNET_MODEL` | Sonnet 模型 | `claude-sonnet-4-20250514` |
| `ANTHROPIC_SMALL_FAST_MODEL` | Haiku 模型 | `claude-haiku-3.5-20241022` |
| `ANTHROPIC_DEFAULT_HAIKU_MODEL` | Haiku 模型 | `claude-haiku-3.5-20241022` |
| `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` | 禁用非必要流量 | `1` |

## 🛡️ 守护进程 (Watchdog)

- **自动检查**：每 10 秒进行一次健康检查。
- **速率限制**：如果服务失败，会自动重启，但在 5 分钟窗口内最多重启 5 次，以防止无限循环。
- **心跳日志**：每 30 秒记录一次心跳信息。
- **自动启动**：随服务一起启动（选项 1 和 6）。
- **日志记录**：详细运行信息记录在 `watchdog.log` 中。

## 📊 仪表板

您可以通过以下链接查看使用情况统计：
[Usage Dashboard](https://ericc-ch.github.io/copilot-api?endpoint=http://localhost:4141/usage)

## 📂 文件结构

```
copilot-api-manager/
├── copilot-manager.sh          # macOS/Linux 管理脚本
├── copilot-manager.ps1         # Windows 管理脚本
├── .gitignore                  # 排除日志和自动生成的脚本
└── README.md                   # 本文件
```

**自动生成的文件 (已在 .gitignore 中忽略):**
- `copilot-watchdog.sh` / `copilot-watchdog.ps1` - 守护进程脚本
- `copilot-api.log` - 服务运行日志
- `watchdog.log` - 守护进程日志

## ❤️ 致谢

- [copilot-api](https://github.com/nicepkg/copilot-api) - 由 nicepkg 开发的核心代理服务。

## 📄 开源协议

MIT
