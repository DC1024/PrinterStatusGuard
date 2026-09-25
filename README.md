# PrinterStatusGuard · 打印机状态守护

一个**免安装、单文件**的 Windows 小工具，把之前讨论的两条「让电脑收到打印机缺纸 / 卡纸 / 缺墨告警」的落地路线合二为一：

- **路线 A（治本）**：帮你把打印机「标准 TCP/IP 端口」上的 **SNMP 状态**打开。开启后，Windows 原生就能在打印机状态里显示「缺纸 / 缺墨」，无需任何第三方软件。
- **路线 B（兜底）**：让工具**常驻后台（托盘 + 开机自启）**，以哨兵方式**轮询打印机的 IPP(631) 状态**，一旦检测到缺纸 / 卡纸 / 缺墨等异常，立刻弹通知（Toast 优先，失败回退气泡）。

两条路线互补：A 让系统自己显示状态，B 在系统看不到的时候（很多打印机不回 SNMP / IPP 不全）仍能主动告警。

v1.1.0 起，原独立工具 **WinPrintDiag**（打印子系统体检，原仓库 [DC1024/winprintdiag](https://github.com/DC1024/winprintdiag)，已归档）**整体并入本程序**，成为主界面的「深度体检」标签页。

> 为什么需要它：打印机卡纸、缺纸时，Windows 默认经常「哑巴」——打印任务卡住、用户跑到打印机前才发现。本工具把状态主动推到桌面通知。

---

## 快速使用

1. 拿到 `PrinterStatusGuard.exe`（已编译好的单文件，**免安装**，放到任意目录双击即可）。
2. 也可以运行 `PrinterStatusGuard.cmd` 启动器：优先用同目录的 `.exe`，找不到时自动回退到 `.ps1`（需要本机有 PowerShell 5.1）。
3. 主界面有五个标签页：
   - **路线 A：启用端口 SNMP** —— 选中打印机的 TCP/IP 端口，点「启用选中端口 SNMP」。需要**管理员权限**（工具会弹 UAC 提权窗口）。开启后 Windows 原生即显示缺纸 / 缺墨。
   - **路线 B：IPP 哨兵** —— 点「添加当前网络打印机」自动导入本机已安装的网络打印机，设置轮询间隔（秒），点「开始哨兵」。异常时弹桌面通知。
     > 「开机自启」通过**最高权限计划任务**实现：勾选时弹一次 UAC 授权，之后每次登录自动以管理员身份在托盘静默运行哨兵（v1.1.1 起取代旧版 HKCU Run 方案，旧条目会在升级后首次运行时自动清理）。该开关自 v1.1.3 起移入「设置」页。
   - **日志（诊断）** —— 查看工具与打印机之间的所有交互消息，支持 `全部 / Info / Warning / Error` 等级筛选、清空、打开日志目录。
   - **深度体检** —— 一键扫描打印子系统（源自 WinPrintDiag），见下文「深度体检」。
   - **设置**（v1.1.3）—— 开机自启、自动检查更新开关、立即检查更新、打开配置/报告目录，与托盘菜单实时同步。
4. 关闭主窗口会**最小化到托盘**而非退出；右键托盘图标可「显示主窗口 / 开始哨兵 / 开机自启 / 退出」。
   > ⚠️ 更新/替换 exe 前：**最小化到托盘不等于退出**，进程仍在运行会占用 `PrinterStatusGuard.exe`，导致文件无法覆盖（报"文件被占用"）。
   > 请先右键托盘图标 → **退出**（或任务管理器结束该进程），确认进程消失后再替换 exe。

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

## 路线 B 原理（IPP 哨兵 + SNMP 交叉确认 + 防抖）

工具周期性向打印机的 `http://<IP>:631/<path>` 发送 **IPP `Get-Printer-Attributes`** 请求，解析：

- `printer-state`（3=空闲 / 4=打印中 / 5=停止）
- `printer-state-reasons`（如 `media-empty` 缺纸、`media-jam` 卡纸、`toner-empty` 缺墨、`cover-open` 盖板未关等）

把 RFC 2911 / 标准关键字翻译成中文 + 严重度分类。

### SNMP 交叉确认
作为补充，哨兵同时读取打印机的 SNMP `hrPrinterDetectedErrorState`（OID `1.3.6.1.2.1.25.3.5.1.2.1`，RFC 2790 位域），覆盖「定影器过热 / 过冷、进纸盘空、耗材缺失」等 IPP 有时不报的厂商自定义位。**IPP 与 SNMP 双通道合并**（见 `Merge-PrinterStatus`）：只要任一通道报卡纸 / 缺纸 / 耗材相关位即判 `Critical`，其余告警判 `Warning`，既确保不漏报，也避免两通道各弹一次。

> 注意：SNMP（RFC 2790）错误位**没有卡纸位**——卡纸只有 IPP 或打印机网页能覆盖，因此双通道合并是必要的。

### 防抖（迟滞）机制
打印机在**扫描、打印、休眠唤醒**时，IPP / SNMP 会短暂失联或抖动——早期版本因此疯狂刷「已恢复」。本工具引入**迟滞规则**：

- **异常（任意错误位）**：立即上报，但同一异常**去重**（不重复弹）。
- **离线**：需**连续 3 次**轮询都离线才判定离线（前 2 次不报）。
- **已恢复**：需**连续 3 次**轮询都正常、且之前确实处于异常 / 离线，才弹「已恢复」。
- **抖动**（离线 / 在线交替）：只要没凑满连续 3 次稳定态，就不刷屏。

由此，扫描等引起的短暂 IPP 失联不再产生一堆「恢复正常」通知。

> 哨兵轮询用的是 `System.Windows.Forms.Timer`，因此工具在 `-Guard`（开机自启）模式下通过 `Application.Run()` 维持消息循环，托盘常驻、定时轮询。

---

## 通知方式

- **优先 Toast**（Windows 10/11 原生 toast）：借助一个 AUMID（`PrinterStatusGuard`）与开始菜单快捷方式注册，无需安装 App。
- **回退气泡（balloon）**：若 Toast 不可用（旧系统 / 组策略禁用），用托盘 `NotifyIcon.ShowBalloonTip` 弹气泡。
- **再回退日志**：若两者都失败，写入日志文件。

---

## 日志与诊断（日志 Tab）

主界面新增 **「日志（诊断）」** 标签页，集中展示工具与打印机之间的所有交互消息，便于排查「为什么没弹通知 / 为什么刷屏」：

- **实时日志表**（时间 / 等级 / 来源 / 消息）：记录启动、每次轮询的**原始 IPP `printer-state-reasons`**、**原始 SNMP 错误位**、状态**合并结果**、通知触发等。
- **等级筛选**：下拉框可切换 `全部 / Info / Warning / Error`，只看关心的级别（Error 行标红、Warning 行标黄）。
- **清空日志**：一键清空内存与表格（不影响已落盘的日志文件）。
- **打开日志目录**：直接打开 `%APPDATA%\PrinterStatusGuard\logs\`，查看按天滚动的 `app-YYYY-MM-DD.log`（UTF-8，无 BOM）。

日志同时写入**内存环形缓冲**（上限 3000 条）与**磁盘文件**，GUI 与文件互不丢失。

---

## 深度体检（WinPrintDiag 并入）

v1.1.0 起，原独立工具 WinPrintDiag 的**完整体检逻辑**并入主程序，成为「深度体检」标签页（不再需要单独下载运行）：

- **一键只读扫描**（约 5 秒）：打印服务状态、spoolsv 崩溃历史（应用日志 1000 / SCM 7031·7034）、打印组件文件签名完好性、打印机/端口/驱动配对（含**同一台打印机重复注册多条目**判定与「建议保留 / 建议删除」、USB 端口挂 IPP 类驱动错配）、打印队列堆积、近期补丁/软件/意外关机、打印审计日志开关。
- **报告**：等宽字体展示，自动落盘到 `%APPDATA%\PrinterStatusGuard\checkup\PrinterCheckup_YYYYMMDD_HHMMSS.txt`（UTF-8 BOM），支持「另存报告」「打开报告目录」。
- **修复组件（管理员）**：对签名异常的系统打印组件，从组件存储（WinSxS）还原，旧文件先隔离备份。
- **清理打印队列**：把卡住的队列文件移到带时间戳的备份目录（不删除任何文件），需管理员。

历史记录：原 [DC1024/winprintdiag](https://github.com/DC1024/winprintdiag) 仓库已归档，其功能全部由本仓库继续提供。

---

## 自测 / 校验

无需界面即可验证核心逻辑（IPP 解析、SNMP 解码、状态合并、防抖迟滞、注册表路径构造、关键函数存在性）：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File PrinterStatusGuard.ps1 -SelfTest
# 或编译后用 exe：
PrinterStatusGuard.exe -SelfTest
```

结果写入同目录 `PrinterStatusGuard_selftest.txt`，`失败用例数: 0` 即通过。当前覆盖 26 个用例，含：

- IPP `printer-state-reasons` 映射与 `printer-state` 解析
- SNMP `hrPrinterDetectedErrorState` OCTET STRING 解码（含单 bit `0x04 → 定影器过热`、多 bit、ErrStatus=0）
- `Merge-PrinterStatus` 双通道合并（正常+过热→Warning、卡纸→Critical、全正常→OK、厂商自定义位→Warning 不漏报）
- 防抖迟滞（异常去重、恢复需连续 3 次、离线需连续 3 次、抖动不刷屏）
- 深度体检全流程（真实扫描一次：产出报告、含结论段、文件落盘）
- 端口 SNMP 注册表路径构造、`Send-Notification` / `Send-Toast` / `Read-Config` 存在性

重新编译（需先有 `ps2exe` 模块）：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File build-exe.ps1
```

生成 `PrinterStatusGuard.exe`（GUI 子系统，无控制台窗口，**含自定义图标** `app.ico`）+ `PrinterStatusGuard.cmd`（GBK 启动器）。若目标 `PrinterStatusGuard.exe` 正在运行被锁，构建脚本自动写入 `PrinterStatusGuard_new.exe` 作为替身，关闭旧实例后手动改名即可。

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
2. Tab **Route A**: select a TCP/IP port → *Enable SNMP* (UAC prompt). Tab **Route B**: *Add current network printers* → set interval → *Start sentinel*; close-to-tray, right-click tray icon to quit. Tab **Log (Diagnostics)**: view all tool↔printer messages with `All / Info / Warning / Error` level filter, clear, and open-log-dir. Tab **Deep Checkup** (v1.1.0, merged from WinPrintDiag): one-click read-only scan of the whole print subsystem.
3. Self-test: `PrinterStatusGuard.exe -SelfTest` writes `PrinterStatusGuard_selftest.txt` (`失败用例数: 0` = pass). 26 cases cover IPP parse, SNMP decode, `Merge-PrinterStatus`, hysteresis, registry path, key functions, and a **full deep-checkup run**.

## Notes

- **Settings tab (v1.1.3):** auto-start, auto update-check toggle, manual update check and open-config-folder live in a dedicated「设置」tab; both UI entry points and the tray menu stay in sync (sentinel state included — tray now shows a checkmark and the main-window button follows).
- **Update check (v1.1.2):** tray menu →「检查更新」queries the GitHub Releases API and compares versions semantically; if a newer release exists you can jump straight to the download page. A **silent check** also runs ~15 s after startup (balloon only when a new version is found), and can be turned off via tray →「自动检查更新」(persisted in config).
- **Auto-start (fixed in v1.1.1):** now implemented as a **scheduled task with highest privileges** (created via a one-time UAC prompt) that runs the tray sentinel at logon — replacing the old HKCU `Run` approach, which neither prompted for admin nor survived startup-app restrictions. Legacy `Run` entries are cleaned up automatically on first run after upgrading.
- **Deep Checkup (merged from WinPrintDiag since v1.1.0):** a one-click read-only scan (~5 s) covering Spooler service state, spoolsv crash history (Event 1000 / SCM 7031·7034), print-stack file signature integrity, printer/port/driver pairing (duplicate entries for the same physical printer with keep/remove advice, USB port on IPP class-driver mismatch), queue backlog, recent patches/software/unexpected shutdowns, and the print audit-log switch. Reports are saved to `%APPDATA%\PrinterStatusGuard\checkup\` and can be saved elsewhere. Admin buttons: *Repair components* (restore suspect print binaries from WinSxS, quarantining originals first) and *Clear print queue* (moves stuck jobs to a timestamped backup folder — nothing is deleted). The standalone repo [DC1024/winprintdiag](https://github.com/DC1024/winprintdiag) is archived; this repo now provides all of its functionality.
- SNMP (RFC 2790) covers empty trays / missing supplies but **not jams**; IPP covers jams. Route B now **merges both channels** (`Merge-PrinterStatus`) so a jam from IPP and a vendor bit from SNMP are never dropped or double-reported.
- **Hysteresis (debounce):** printers briefly drop IPP/SNMP during scanning/printing/sleep, which used to spam "recovered". Anomaly fires immediately (deduped); *offline* and *recovered* each require **3 consecutive stable polls** before firing, so a scan-induced blip no longer floods notifications.
- Log tab writes both an in-memory ring buffer (3000) and daily files at `%APPDATA%\PrinterStatusGuard\logs\app-YYYY-MM-DD.log`.
- Rebuild: `powershell -File build-exe.ps1` (needs the `ps2exe` module). Produces a GUI-subsystem x64 exe with a **custom icon** (`app.ico`) + a GBK `.cmd` launcher. If the target exe is locked, it writes `PrinterStatusGuard_new.exe` instead.
- Requires .NET Framework 4.x and Windows PowerShell 5.1 (built into Windows 10/11). Config lives in `%APPDATA%\PrinterStatusGuard\`.
