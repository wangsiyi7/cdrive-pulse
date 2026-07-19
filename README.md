# cdrive-pulse（C盘脉搏）

> 让任何人 5 分钟看清并安全瘦身 C 盘。

纯 PowerShell 5.1+ 实现的 Windows C 盘空间监测与清理工具：**任何 Windows 开箱即用，零依赖**。
它源于一次真实清理实战（2026-07：C 盘从 116 GB 已用清出 34 GB），把那次实战的流程沉淀成了可复用、可扩展的规则化工具。

## 特性

- **六区扫描法**：磁盘总览 + 按规则库逐条测量热点目录（缓存、应用数据、系统残留、开发工具链……），用 `robocopy /L /XJ` 快速测量，防 junction 循环
- **四象限分类**：`safeCache`（安全缓存，可放心删）/ `caution`（谨慎，需人工确认）/ `system`（系统目录，勿手动删）/ `migrate`（建议迁移到其他盘）
- **安全铁律**：
  1. 干跑（dry-run）是默认行为，必须显式 `-Execute` 才真正删除
  2. 删除前验证路径存在、不是符号链接 / Junction（链接一律跳过并警告）
  3. 占用 / 拒绝访问的文件跳过并计数，**绝不强杀进程**
  4. 删除前后各测一次大小，输出释放统计，全程写日志
- **前后对比**：`report` 命令对比两次扫描，逐目录展示释放量
- **规则可扩展**：`rules.json` 声明式规则库，路径支持 `%USERPROFILE%` 等环境变量与 `*` 通配，支持「仅删 N 天前」「保留最新版」「保留指定文件」等精细语义
- **双输出**：机器可读 JSON（`out\scan-latest.json`）+ 人读 Markdown 报告（`out\report-latest.md`）

## 快速开始

```powershell
# 在工具目录下（无需安装，PowerShell 5.1+ 即可）
powershell -ExecutionPolicy Bypass -File cpulse.ps1 scan
```

扫描完成后查看：

- `out\report-latest.md` — 人读报告（按类别分组、按大小排序）
- `out\scan-latest.json` — 机器可读结果

## 命令用法

```powershell
# 1. 扫描：C 盘容量 + 逐条规则测目录大小
.\cpulse.ps1 scan

# 2. 干跑清理（默认行为，只列不删，输出预计释放量）
.\cpulse.ps1 clean -WhatIf

# 3. 真正执行清理（遵守安全铁律，日志写入 out\clean-log-<时间戳>.txt）
.\cpulse.ps1 clean -Execute

# 4. 对比两次扫描（清理前后的释放统计）
.\cpulse.ps1 report out\scan-latest.json out\scan-latest.json   # 示例：换成清理前后各自备份的 scan json
.\cpulse.ps1 report 旧scan.json 新scan.json

# 5. 列出当前规则库
.\cpulse.ps1 rules
```

> 建议：清理前先把 `out\scan-latest.json` 复制备份一份，清理后再跑一次 `scan`，用 `report` 对比战果。

## 扫描输出格式

`out\scan-latest.json`：

```json
{
  "generatedAt": "2026-07-15T10:30:00+08:00",
  "drive": { "totalGB": 237.5, "usedGB": 116.2, "freeGB": 121.3, "percent": 48.9 },
  "groups": [
    {
      "id": "cache-yarn",
      "name": "Yarn 全局缓存",
      "path": "%LOCALAPPDATA%\\Yarn\\Cache",
      "sizeGB": 2.31,
      "category": "safeCache",
      "note": "包管理器下载缓存，删除后按需重新下载",
      "exists": true
    }
  ]
}
```

注意：JSON 中的 `path` 保留环境变量模板，**不输出真实用户名**，可安全分享。

## 规则格式说明（rules.json）

每条规则：

| 字段 | 必填 | 说明 |
| --- | --- | --- |
| `id` | 是 | 唯一标识 |
| `name` | 是 | 展示名 |
| `path` | 是 | 目录路径，支持 `%USERPROFILE%` / `%LOCALAPPDATA%` / `%APPDATA%` / `%WINDIR%` / `%SYSTEMDRIVE%` 等环境变量，支持 `*` 通配（匹配目录） |
| `category` | 是 | `safeCache` / `caution` / `system` / `migrate` |
| `action` | 是 | `delete`（进入清理清单）/ `reportOnly`（仅测量报告） |
| `note` | 否 | 说明文字 |
| `maxAgeDays` | 否 | 仅删除 N 天前的文件（如 Temp） |
| `keepLatestSubdir` | 否 | `true` 时保留版本号最大的子目录，删除其余（如 WPS 旧版本） |
| `keepFiles` | 否 | 删除目录内容时保留指定文件名（如 Squirrel 的 `Update.exe`） |

只有 `action = delete` 的规则会进入 `clean` 的清理清单；其余仅在 `scan` 中测量展示。

## 实战战绩

2026-07 实测（Windows 11 开发机）：C 盘已用 **116 GB → 83 GB**，释放 **34 GB**。

主要释放来源：开发工具链缓存（Yarn / npm / pnpm / uv / go-build / Playwright / cargo-xwin）、
WPS 旧版本与插件缓存、视频客户端缓存、崩溃转储、临时文件，以及把 cargo / rustup / go / WPSDrive 迁移到 D 盘。

## 免责声明

本工具按“原样”提供，不附带任何明示或暗示的担保。`clean -Execute` 会真实删除文件：
请务必先 `scan` 看清报告、先 `clean -WhatIf` 确认清单，自行判断每条规则是否适用于你的机器。
`caution` / `system` 类规则默认仅报告不删除，请勿手动删除系统目录（WinSxS、Windows\Installer 等），
请使用系统自带的磁盘清理或 DISM。作者不对因使用本工具造成的数据丢失负责。

## 贡献指南

欢迎贡献！

- **新增规则**：把你实测过的 C 盘热点目录按上面的格式加进 `rules.json`，注明类别与安全语义，提 PR
- **改进代码**：`cpulse.ps1` 保持 PowerShell 5.1 兼容、零依赖、中文注释
- **反馈问题**：提 Issue，附上 `out\scan-latest.json`（不含个人信息）与复现步骤

开发约定：不读取 / 不输出任何用户敏感信息；规则路径一律用环境变量通用化，不硬编码用户名。

## 许可证

[MIT](LICENSE)
