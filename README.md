# PrinterStatusGuard · 打印机状态守护

一个**免安装、单文件**的 Windows 小工具，把之前讨论的两条「让电脑收到打印机缺纸 / 卡纸 / 缺墨告警」的落地路线合二为一：

- **路线 A（治本）**：帮你把打印机「标准 TCP/IP 端口」上的 **SNMP 状态**打开。开启后，Windows 原生就能在打印机状态里显示「缺纸 / 缺墨」，无需任何第三方软件。
- **路线 B（兜底）**：让工具**常驻后台（托盘 + 开机自启）**，以哨兵方式**轮询打印机的 IPP(631) 状态**，一旦检测到缺纸 / 卡纸 / 缺墨等异常，立刻弹通知（Toast 优先，失败回退气泡）。

两条路线互补：A 让系统自己显示状态，B 在系统看不到的时候（很多打印机不回 SNMP / IPP 不全）仍能主动告警。

> 为什么需要它：打印机卡纸、缺纸时，Windows 默认经常「哑巴」——打印任务卡住、用户跑到打印机前才发现。本工具把状态主动推到桌面通知。

---

## 快速使用

1. 拿到 `PrinterStatusGuard.exe`（已编译好的单文件，**免安装**，放到任意目录双击即可）。
2. 也可以运行 `PrinterStatusGuard.cmd` 启动器：优先用同目录的 `.exe`，找不到时自动回退到 `.ps1`（需要本机有 PowerShell 5.1）。
3. 主界面有两个标签页：
   - **路线 A：启用端口 SNMP** —— 选中打印机的 TCP/IP 端口，点「启用选中端口 SNMP」。需要**管理员权限**（工具会弹 UAC 提权窗口）。开启后 Windows 原生即显示缺纸 / 缺墨。
   - **路线 B：IPP 哨兵** —— 点「添加当前网络打印机」自动导入本机已安装的网络打印机，设置轮询间隔（秒），勾选「开机自启」，点「开始哨兵」。异常时弹桌面通知。
4. 关闭主窗口会**最小化到托盘**而非退出；右键托盘图标可「显示主窗口 / 开始哨兵 / 开机自启 / 退出」。

---

## 路线 A 原理（端口 SNMP）

Windows 的「标准 TCP/IP 端口」默认**不启用 SNMP**。工具向注册表写入（需管理员）：

```
HKLM\SYSTEM\CurrentControlSet\Control\Print\Monitors\Standard TCP/IP Port\Ports\<端口名>
  SNMP Enabled    = 1
  SNMP Community  = public
  SNMP Index      = 1
  PortMonMibPortIndex = 1
```

然后重启 **Print Spooler** 服务让设置生效。之后 Windows 打印系统即可通过 SNMP 读取打印机的 `hrPrinterDetectedErrorState`，在设备和打印机里显示缺纸 / 缺墨等状态。

> 说明：SNMP（RFC 2790）的错误位覆盖「进纸盘空 / 耗材缺失」等，但**没有卡纸位**——卡纸信息只有 IPP（见路线 B）或打印机网页能覆盖。

---

## 路线 B 原理（IPP 哨兵）

工具周期性向打印机的 `http://<IP>:631/<path>` 发送 **IPP `Get-Printer-Attributes`** 请求，解析：

- `printer-state`（3=空闲 / 4=打印中 / 5=停止）
- `printer-state-reasons`（如 `media-empty` 缺纸、`media-jam` 卡纸、`toner-empty` 缺墨、`cover-open` 盖板未关等）

把 RFC 2911 / 标准关键字翻译成中文 + 严重度，仅在**状态发生变化且为异常或恢复**时弹通知，避免刷屏。
作为补充，也可叠加 SNMP 错误位做交叉确认。

> 哨兵轮询用的是 `System.Windows.Forms.Timer`，因此工具在 `-Guard`（开机自启）模式下通过 `Application.Run()` 维持消息循环，托盘常驻、定时轮询。

---

## 通知方式

- **优先 Toast**（Windows 10/11 原生 toast）：借助一个 AUMID（`PrinterStatusGuard`）与开始菜单快捷方式注册，无需安装 App。
- **回退气泡（balloon）**：若 Toast 不可用（旧系统 / 组策略禁用），用托盘 `NotifyIcon.ShowBalloonTip` 弹气泡。
- **再回退日志**：若两者都失败，写入日志文件。

---

## 自测 / 校验

无需界面即可验证核心逻辑（IPP 解析、SNMP 解码、状态映射、注册表路径构造）：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File PrinterStatusGuard.ps1 -SelfTest
# 或编译后用 exe：
PrinterStatusGuard.exe -SelfTest
```

结果写入同目录 `PrinterStatusGuard_selftest.txt`，`失败用例数: 0` 即通过。

重新编译（需先有 `ps2exe` 模块）：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File build-exe.ps1
```

生成 `PrinterStatusGuard.exe`（GUI 子系统，无控制台窗口）+ `PrinterStatusGuard.cmd`（GBK 启动器）。

---

## 权限与安全

- **路线 A 写入 HKLM 注册表 + 重启 Spooler**：需管理员；工具用 `RunAs` 提权子进程完成，非管理员主界面不直接写系统。
- **路线 B 只发网络请求读状态**：普通用户权限即可，无需提权。
- 单文件 exe 由 `ps2exe` 把脚本嵌入生成，运行需本机有 .NET Framework 4.x 与 Windows PowerShell 5.1（Win10/11 自带）。
- 不收集任何数据，所有配置存在 `%APPDATA%\PrinterStatusGuard\`。

---

## 技术栈

PowerShell 5.1（IPP 客户端 + SNMP 客户端均纯 .NET 实现，无外部依赖）→ `ps2exe` 编译为免安装单文件 exe（x64 / GUI 子系统）。

---

# PrinterStatusGuard (English)

A **portable, single-file** Windows utility combining two ways to get printer status alerts (paper empty / jam / toner low) on your desktop:

- **Route A (root fix):** enable **SNMP** on the printer's *Standard TCP/IP Port* so Windows itself shows paper/toner status natively (writes `HKLM\...\Standard TCP/IP Port\Ports\<port>` + restarts the Print Spooler; requires Admin).
- **Route B (fallback):** run a **background sentinel** (tray + auto-start) that polls each printer's **IPP (port 631)** `Get-Printer-Attributes`, and shows a **desktop notification** (Toast, with balloon fallback) when `printer-state-reasons` reports an anomaly.

## Usage

1. Run `PrinterStatusGuard.exe` (portable, no install). Or `PrinterStatusGuard.cmd` (launches the exe, falls back to the `.ps1` if absent).
2. Tab **Route A**: select a TCP/IP port → *Enable SNMP* (UAC prompt). Tab **Route B**: *Add current network printers* → set interval → *Start sentinel*; close-to-tray, right-click tray icon to quit.
3. Self-test: `PrinterStatusGuard.exe -SelfTest` writes `PrinterStatusGuard_selftest.txt` (`失败用例数: 0` = pass).

## Notes

- SNMP (RFC 2790) covers empty trays / missing supplies but **not jams**; IPP covers jams. That's why both routes exist.
- Rebuild: `powershell -File build-exe.ps1` (needs the `ps2exe` module). Produces a GUI-subsystem x64 exe + a GBK `.cmd` launcher.
- Requires .NET Framework 4.x and Windows PowerShell 5.1 (built into Windows 10/11). Config lives in `%APPDATA%\PrinterStatusGuard\`.
