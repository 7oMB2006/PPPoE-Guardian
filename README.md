# PPPoE-Guardian 宽带连接守护

宿舍/校园 PPPoE 宽带经常"连上就掉、要反复拨几次才稳"？PPPoE-Guardian 替你盯着：**掉线自动重拨，连续稳定 10 分钟后自动退出**，全程无需值守。

## 它做了什么

- **双重掉线检测**：`rasdial` 拨号状态 + ping 真实连通性，连续 2 次异常才判定掉线，单次丢包不误杀好连接
- **拟人拨号（默认）**：通过 Windows UI Automation 在"设置 → 拨号"页里点击「宽带连接」卡片的**连接按钮**——和你手动点完全同一条路径、同一套系统记住的凭据，后台触发、不抢鼠标焦点、不依赖窗口位置
- **启动时准备窗口**：GUI 模式启动后自动检查"设置 → 拨号"窗口；窗口不存在时自动打开，确保后续 UI Automation 拨号有可用目标
- **rasdial 拨号（备选）**：命令行拨号模式，可显式配置账号密码
- **防误杀时序**：拨号后轮询 30 秒等 IP 就绪再判成败；断开前先观察 15 秒防止误杀刚拨通的连接
- **退避重试**：失败越多等越久（10s→60s），给网关释放旧会话留时间，最多 15 次后弹窗退出
- **干净启动**：启动时发现旧守护实例会询问是否关闭后再运行
- **自动退出**：连续稳定达设定时长（默认 10 分钟）后记日志退出
- **零依赖**：仅需 Windows 10/11 自带的 PowerShell，无需安装任何东西

## 快速开始

1. 确保已在 Windows「设置 → 网络和 Internet → 拨号」里创建好宽带连接（PPPoE），且系统记住了账号密码（手动点一次「连接」并勾选记住即可）
2. 双击 `start_guard.bat`（若检测到多个拨号条目会让你选择）
3. 完事。掉线它会自动拨，稳定 10 分钟后自动退出

> 建议给 `start_guard.bat` 创建桌面快捷方式。脚本目录下的 `guard.log` 记录了每次掉线/重拨/成功的时间线。

## 配置

所有配置都在 `broadband_guard.ps1` 顶部的配置区：

| 变量 | 默认值 | 说明 |
|---|---|---|
| `$connName` | `""` | 拨号连接名。**留空自动检测**（读系统电话簿 rasphone.pbk），多个条目时交互选择；也可手动指定如 `"宽带连接 2"` |
| `$pingTargets` | 223.5.5.5 / 119.29.29.29 | 连通性探测目标，任一通即算在线，可换成你的网关 IP |
| `$checkInterval` | 10 秒 | 在线时的巡检间隔 |
| `$stableMinutes` | 10 分钟 | 连续稳定多久后自动退出 |
| `$maxRetries` | 15 次 | 连续重拨失败多少次后放弃并弹窗 |
| `$dialMethod` | `"gui"` | `"gui"`=拟人点击设置页连接按钮（推荐）；`"rasdial"`=命令行拨号 |
| `$broadbandUser` / `$broadbandPass` | 空 | 仅 rasdial 方式使用；gui 方式用系统记住的凭据 |

## 拨号方式怎么选

- **`gui`（默认）**：等价于你手动点「连接」，使用设置界面记住的凭据。校园网对命令行拨号报 628 时优先用它
- **`rasdial`**：更轻量，但空凭据拨号可能被网关拒绝（错误 628/691），此时在配置区填入宽带账号密码

## 常见拨号错误

| 错误码 | 含义 | 应对 |
|---|---|---|
| 628 | 连接被远程计算机终止 | 网关未释放旧会话或拒绝空凭据；脚本会退避重试，持续失败换 `gui` 模式或填账号密码 |
| 691 | 用户名/密码被拒 | 检查账号密码、是否被别的设备挤下线 |
| 651 | 调制解调器/网卡错误 | 检查物理链路或网卡驱动 |

## 已知限制

- GUI 拨号模式的按钮定位支持中文/英文系统界面
- 弹窗提示与日志目前为中文
- 需要 Windows 10/11（依赖 UI Automation 与 ms-settings 协议）

## 只读检查

想看当前状态而不启动守护：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File broadband_guard.ps1 -Check
```

输出示例：`当前状态: 拨号[已连接] 网络[通畅]`，不会拨号也不会断网。

---

## English Summary

PPPoE-Guardian watches your Windows PPPoE (broadband/dial-up) connection: on disconnect it auto-redials — by invoking the **Connect button in Windows Settings via UI Automation** (same as clicking it yourself, using saved credentials) or via `rasdial`. Exits automatically after the link stays stable for a configurable time (default 10 min). Zero dependencies beyond built-in PowerShell. Chinese UI/log;中文说明见上文。

## License

MIT — see [LICENSE](LICENSE)
