# MacMonitor design

Date: 2026-10-28. This is the original design spec the app was built from. Some numbers below are from the one Mac it was built on.

## 1. Intent

One native Mac app that gives a full, live picture of a MacBook Pro's hardware: heat, load, power, memory, disks, battery, network and apps. The headline question is **"why is my fan on right now?"**, answered in one plain sentence. Claude (or any MCP client) can read the same data through an MCP server, so you can ask about your Mac in any session.

It goes deeper than iStat Menus or Stats, using hidden but readable macOS data sources, with lots of graphs and animation.

Machine: MacBook Pro Mac16,8, Apple M4 Pro (10 P cores, 4 E cores, 20 GPU cores), 48 GB, macOS 26.5, two fans. Only Command Line Tools are installed (no Xcode app).

## 2. Goals

- A native SwiftUI app with a menu bar item and a main window.
- Every reading in `research/2026-10-28-macmonitor-data-sources.md` that tested as working, shown somewhere in the app.
- A "why the fan is on" headline that names the hot part and the top apps behind it.
- Live charts with smooth animation, plus history: 24 hours at full detail, then per-minute summaries for 30 days.
- Mac notifications (alerts) for real events, each with an on/off switch, plus an Events log.
- A stdio MCP server exposing the same data as tools, which a user can register in Claude Code.
- A short README.

## 3. Non-goals

- Fan control or any write to the SMC. Read only, always.
- Anything that needs root or a password. `powermetrics` is out. No sudo prompts, no privileged helper.
- Supporting Intel Macs or other Apple Silicon models. It should not crash on them, but labels and layouts are tuned for this M4 Pro.
- App Store distribution, notarization, auto-update.
- Remote monitoring of other machines.

## 4. Anti-goals (failure even if it "works")

- **The monitor heats the Mac.** Budget, measured as `ps` %CPU where 100% = one core, averaged over 60 s, and counting any child processes the app launches (`top`, `ps`): at most 3% with only the menu bar running (about 0.2% of the whole 14-core Mac), at most 15% with the main window open and animating (about 1% of the whole Mac). If the 1 s set cannot meet the menu-bar budget, cut the SMC key list and HID reads first; IOReport and host stats stay at 1 s because history depends on them. Measure it.
- **Made-up facts.** Any label we have not proven (many SMC key names) must say "best guess" in the UI or be shown as raw key names. Never claim a cause we cannot back with readings. The fan headline must state the readings it used.
- **Disk bloat.** Many Macs run with little free disk space. History on disk must stay under 150 MB.
- **Alert spam.** Each alert type has a cooldown, and nothing fires more than once per 15 minutes per type by default.
- Asking for or storing any password.

## 5. Design decisions

- Look: a combo of three mockups (screens saved in `docs/mockups/`):
  - **Overview** page: dark, dense live line graphs (CPU, GPU, hottest temp, fan), a stacked "watts by part" graph, and an orange "why the fan is on" bar.
  - **Chip map** page: a schematic of the M4 Pro die (P cores, E cores, GPU, Neural Engine, memory, media). Each block glows from blue to red by its live temperature. One bar per core below (10 P, 4 E).
  - **Detail pages** in a calm, roomy style (like System Settings): Heat & fans, CPU, GPU, Memory, Power & battery, Disks, Network, Apps, plus Events. Each row has a bar; clicking a row slides open its history chart.
  - A **sidebar** on the left, each item with a live number next to it.
  - Dark or light follows the macOS setting.
  - Lots of motion: numbers tick smoothly, bars slide, chart lines move, the fan icon spins at a speed tied to real RPM.
- Menu bar: a small live sparkline plus CPU %, hottest temp and fan RPM. Clicking opens a popover with key numbers, the fan headline, and a button to open the window.
- Alerts: on (Mac notifications), each type switchable, plus the Events log.
- Starts at login.

## 6. Architecture

One Swift package, built with Command Line Tools only (`swift build`), then wrapped into an `.app` by a script.

| Target | Kind | Job |
|---|---|---|
| `CSensors` | C library | Thin C wrappers over private APIs: AppleSMC user client, IOReport (`-lIOReport`), IOHIDEventSystemClient sensors, NVMe SMART plug-in, HID lid angle. Port from the working probes in `research/`. |
| `MonitorCore` | Swift library | Samplers, the `Snapshot` model (Codable), history store (SQLite via the system `libsqlite3`), fan explainer, event detector, alert rules. No UI. |
| `MacMonitor` | Swift executable, SwiftUI app | Menu bar item, main window, charts, settings, notifications. Runs the sampler and writes history. |
| `macmonitor-mcp` | Swift executable | stdio MCP server. Hand-rolled JSON-RPC 2.0 (no new dependencies). |
| `MonitorCoreTests` | XCTest or swift-testing | Unit tests for parsing, rules, rollups, MCP protocol. |

**No third-party dependencies.** System frameworks only: SwiftUI, Charts, IOKit, CoreWLAN, UserNotifications, ServiceManagement, libsqlite3, libIOReport.

**Data flow.**
- The app is the only sampler that writes history. It samples on fixed clocks:
  - 1 s: CPU ticks per core, memory, swap, IOReport power and clocks and GPU residency, SMC fans and a chosen key list (20 to 40 keys), GPU PerformanceStatistics, network counters, disk I/O counters, thermal state.
  - 5 s: per-process data (`proc_pid_rusage` V6 for own processes; GPU time per process from `AGXDeviceUserClient`; `ps` for root processes' CPU and memory).
  - 60 s: NVMe SMART, battery details, adapter, volumes, display, lid angle, HID named sensors.
  - `top` (setuid, gives root process POWER and kernel_task CPU) only every 15 s, and only while the fan is ramping or the window is open. It costs about 1 s of wall time per call, so run it off the main thread.
- The MCP server never needs the app to be running:
  - `get_snapshot` and live tools read the app's latest row if it is under 3 s old; otherwise they sample live with `MonitorCore` (about a 1 s window for deltas).
  - History and events come from SQLite. If the app has not been running, history tools say so plainly instead of returning empty silence.
- Paths: `~/Library/Application Support/MacMonitor/history.sqlite`. WAL mode so the app writes while the MCP reads.

**History store (builder chooses the exact schema, within these limits).**
- Full detail: a fixed list of headline metrics (about 40 numbers) at 1 Hz for 24 hours.
- Rollups: per-minute avg, min and max for the same metrics, kept 30 days.
- Process top-N every 5 s for 24 hours (top 10 by CPU, energy and GPU), per-minute top 5 for 30 days.
- Events table: kept 30 days.
- Prune at most once a minute. Total size under 150 MB; prove it with a size estimate and a measured file after a run.

## 7. What each page shows

Every value listed in the research report's TL;DR and Wow list that tested as working on this Mac has a home here. If a source fails at runtime, the row hides itself or shows "not available", never a fake zero.

- **Overview:** CPU %, GPU %, hottest temp, fan RPM tiles with sparklines; stacked watts by part (P clusters, E cluster, GPU, ANE, DRAM plus memory system); system power total and wall power; thermal pressure chip; the fan headline bar; top 3 apps by energy.
- **Chip map:** schematic die with live temps per block (P-core cluster from `Tp*` max, E cores from `Te*`, GPU from `Tg*`, Neural Engine power-based glow, memory from DRAM power), per-core load bars, per-cluster MHz (both "asked for" per-core and "cluster runs at" PCPM / ECPM, labeled as such), per-core watts on hover. Label the die "schematic, not to scale".
- **Heat & fans:** each fan: actual, target, min, max, duty, state (off, ramping up, ramping down, steady), "heading to N RPM". Hottest sensors list. All SMC temperature keys grouped (P cores, E cores, GPU, battery, SSD area, palm rest, air flow, Wi-Fi, ambient, unknown), groups with "best guess" tags where not proven. HID named sensors (PMU tdie 1 to 14, NAND, battery). Thermal pressure level and history. GPU CLTM cap. Temperature limits keys shown raw.
- **CPU:** per-core load (P and E), load averages, per-core and per-cluster MHz, per-core watts, kernel_task CPU (throttle sign), P vs E time for top apps.
- **GPU:** device, renderer, tiler %; GPU MHz and active residency; GPU memory in use and allocated; GPU power; GPU time per app (including WindowServer); GPU resets count; CLTM and power target %.
- **Memory:** used, app, wired, compressed (and how much it holds, "66.9 GB squeezed into 16.2 GB"), cached, free, swap used of total, pressure level and memorystatus percent, page-ins, swap-ins and swap-outs rates.
- **Power & battery:** system power (PSTR), adapter power in (PDTR), battery power (PPBR), wall power from `PowerTelemetryData`, adapter efficiency loss; battery: percent, charging state, cycles of 1,000 design, health shown three ways and labeled (Apple's "Maximum Capacity" as System Settings shows it, raw max vs design, and the IOPS `BatteryHealth` flag; these disagree on this Mac and the UI must say which source each is), cell voltages, battery temperature, lifetime max temp and currents, cell resistance; adapter name, watts, serial-free summary (do not display serials by default), USB-PD menu; display nits and brightness; lid angle.
- **Disks:** each volume's used, free, "available for important use", purgeable; read and write speed per disk; IOPS and average latency; bytes since boot; NVMe SMART: temperature, % used (wear), TB written and read, power-on hours, power cycles, unsafe shutdowns, media errors, spare; SSD controller interrupts per second; a "swap is writing to your SSD" note when swap-outs are high (state it as a correlation, not a proven cause).
- **Network:** per-interface up and down speed with 64-bit counters, link speed; Wi-Fi RSSI, noise, rate, channel when Wi-Fi is on (no SSID; it needs Location and we will not ask); Wi-Fi chip temp from IOReport if present.
- **Apps:** sortable table of processes: CPU %, memory (footprint), energy (W), P vs E split, GPU %, wakeups per second, disk read and write rate. Root processes show only what `ps` and `top` give, marked as such.
- **Events:** a timeline of fan ramps (with cause), thermal pressure changes, throttle signs, memory pressure changes, swap near full, disk low, SSD hot, battery flag changes, sleep and wake (from `kern.waketime` changes).
- **Settings:** alert switches and thresholds, launch at login, sample-rate preset (normal or eco), history size shown in MB with a "clear history" button.

## 8. Why the fan is on (rules)

Use the rule set in section "Why is the fan on?" of the research report, with these additions:
- Fan state from target vs actual (50 RPM band) and the 10 s target trend.
- Heat source from power averaged over the last 60 s by block; name the biggest block and its share.
- Top causes: rank processes by energy over the same 60 s (own processes by `ri_energy_nj`, root ones by `top` POWER when available, GPU by GPU time).
- If CPU plus GPU power is low but the fan is on, fall back to: charging, SSD temp, palm rest and air temps, lid angle, ambient.
- The headline always lists the numbers it used, for example: "Fan at 4,600 RPM, slowly falling. P cores used 23 W over the last minute (85% of chip power). Top: Virtualization 1.5 W, Python 1.5 W."
- These are our rules, not Apple's fan curve. The UI says so in the info popover.

## 9. Alerts

Mac notifications via UserNotifications. Each type has a switch and a cooldown (default 15 min):
- Fan ramp: the fan target crosses into "loud" (default 5,000 RPM, editable) after the fans were under 3,500 RPM for at least 10 minutes. Staying loud does not re-fire. A Mac that often runs VMs or Docker can sit with fans near 5,000 RPM, so a plain threshold would spam. The headline is the body.
- Thermal pressure reaches heavy (2) or worse.
- Throttle sign: GPU CLTM not `NO_CLTM`, or kernel_task CPU above 50% for 30 s.
- Memory pressure warn or critical; swap over 90% of its total.
- Startup disk free under 10 GB.
- SSD temperature over 70 C.
- Battery health flag changes.
Every alert also writes an Events row. Notification permission is asked once on first launch; if denied, Events still work.

## 10. MCP server

stdio, JSON-RPC 2.0, MCP protocol version negotiated in `initialize` (support `2025-06-18` and accept older client versions). Tools (all read only):
- `get_snapshot`: everything current, grouped by area, with units in key names.
- `get_history(metric, minutes, resolution?)`: points for one metric; `list_metrics` tells the names.
- `list_metrics`: metric names, units, descriptions.
- `top_processes(sort_by: cpu|memory|energy|gpu|disk, limit)`.
- `why_fan`: the headline plus the readings behind it.
- `get_events(hours, kind?)`.
- `get_sensors(group?)`: all temperature sensors with source (SMC or HID), key, label, and whether the label is proven.
- `get_hardware_health`: SSD SMART, battery health (all three views), adapter, display.
Register it with Claude Code at user scope (`claude mcp add -s user ...`), pointing at the binary inside the installed app bundle. Prove it by calling each tool from a real `claude -p` session and through a raw stdio test.

## 11. Build, install, run

- `swift build -c release`, then `scripts/bundle.sh` makes `MacMonitor.app` (Info.plist with bundle id `com.macmonitor.app`, `LSUIElement` true so it lives in the menu bar; switch the activation policy to `.regular` while the main window is open so it shows in the Dock and Cmd-Tab, then back to `.accessory` when closed), app icon from SF Symbols or a simple generated icon), ad-hoc signs it (`codesign -s -`), and copies it to `~/Applications`.
- The MCP binary ships inside the bundle at `Contents/MacOS/macmonitor-mcp`.
- Launch at login via `SMAppService.mainApp`; if that fails for an ad-hoc signed app, fall back to a user LaunchAgent plist. No admin rights either way.

## 12. Proof required before "done"

- `swift build` and tests pass, log shown.
- The app runs from `~/Applications`, screenshots of each page in dark mode, and Overview plus one detail page in light mode.
- CPU cost measured with the window closed and open (`ps` or `top` over 60 s), within budget.
- History DB size after a measured run, and the projected 30 day size.
- A notification fired for real (lower a threshold temporarily to trigger it), and an Events row.
- Real output from every MCP tool, through raw stdio and through a `claude -p` session.
- A fresh code review of all code before done; fix rounds re-checked.

## 13. Left to the builder

- Exact SQLite schema and metric names (within section 6 limits).
- Exact SMC key list for the 1 s set (start from `research/fan_watch.c`), key info caching.
- Which IOReport channels to subscribe for the 1 s set (keep the subscription small for cost).
- The die schematic geometry, colors, fonts, animation curves, within the look above.
- App icon.
- Whether processes from `ps` and from `proc_pid_rusage` merge into one table (they should, keyed by pid).

## 14. Known unknowns (show honestly, do not guess)

- Per-core "asked for" MHz vs cluster PCPM MHz: show both, labeled.
- Two GPU power channels disagree (`GPU` mJ vs `GPU Energy` nJ); use `GPU`, mention the other in a tooltip.
- Many SMC temperature keys have unproven labels.
- Battery health sources disagree (System Settings "Normal 86%" vs IOPS "Check Battery" vs raw 81.6%).
- Wi-Fi, Bluetooth device batteries, Thunderbolt link speed: untested; build them so they show "not available" cleanly.
