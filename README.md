# MacMonitor

**MCP for your Mac hardware.** Works with Claude and Codex.

MacMonitor is a free, open-source Mac app that shows what your Mac's hardware is doing, live.
It answers one question first: **why is my fan on right now?**

It lives in the menu bar, opens a window full of live graphs, keeps history, sends alerts,
and lets AI agents like Claude and Codex read the same data through an MCP server.

It reads hardware sensors read only. It never writes to the hardware, never needs an admin password, and sends nothing over the network.

![Overview page](docs/screenshots/01-overview-dark.png)

## Which Macs it works on

- **Built for Apple Silicon Macs** (M-series chips).
- **Tested on one Mac:** a MacBook Pro with an M4 Pro chip, on macOS 26.
- **Needs macOS 15 or newer** to build and run.
- On other Apple Silicon chips it should run, but some sensor names, the chip map drawing and the core layout are tuned
  for the M4 Pro. A reading it cannot find shows "not available" instead of a wrong number.
- Intel Macs are not supported.

## What you get

- **Menu bar:** a tiny CPU graph plus `CPU 42% · 71° · 2.3k` (CPU, hottest temperature, fan RPM).
  Click it for key numbers, the fan headline and an "Open MacMonitor" button.
- **Overview:** CPU, GPU, hottest temperature and fan tiles with moving graphs, power by chip part,
  system and wall power, thermal pressure, and the top apps by energy.
- **Chip map:** a drawing of the M4 Pro chip. Each block glows blue (40°) to red (100°) with its live
  temperature. One bar per core (10 P cores, 4 E cores), with clocks and watts.
- **Detail pages:** Heat & fans, CPU, GPU, Memory, Power & battery, Disks, Network, Apps.
  Click a row to open its history chart (15 minutes, 1 hour, 24 hours or 30 days).
- **Events:** fan ramps, heat, throttle signs, memory, swap, disk, SSD, battery flag and wake.
- **Settings:** alert switches and thresholds, start at login, sample rate, history size and a clear button.

Sensor names we have not proven carry a **best guess** tag. A reading that is missing shows
"not available" or `--`, never a fake zero.

## Download

1. Get `MacMonitor-<version>.zip` from the [latest release](https://github.com/primemindai/macmonitor/releases/latest).
   It is for Apple Silicon Macs on macOS 15 or newer.
2. Double-click the zip, then drag `MacMonitor.app` into your Applications folder.
3. Open it. The first time, macOS says **"Apple could not verify MacMonitor"**. This is because the app is
   not signed with a paid Apple Developer ID yet. Click **Done**, then pick one fix:
   - **System Settings:** open **Privacy & Security**, scroll down to "MacMonitor was blocked", click
     **Open Anyway**, and confirm with your password or Touch ID.
   - **Terminal:** run this once, then open the app again.

     ```bash
     xattr -dr com.apple.quarantine /Applications/MacMonitor.app
     ```

You only do this once. Prefer to check the code first? Build it yourself (next section).

## Build and install from source

You need Apple's Command Line Tools (no Xcode needed). There are no third-party packages.

```bash
xcode-select --install                     # skip if the Command Line Tools are already installed
git clone https://github.com/primemindai/macmonitor.git MacMonitor
cd MacMonitor
```

Build only (to check it compiles):

```bash
swift build
```

Build, install and open the app:

```bash
scripts/bundle.sh --open
```

This builds a release copy, wraps it in `MacMonitor.app`, signs it ad hoc, installs it to
`~/Applications/MacMonitor.app` and opens it. The first launch asks once for notification permission
and turns on "start at login".

Make a release zip (what the Releases page ships; it does not install anything):

```bash
scripts/release.sh 1.0.0
```

Run the tests. Use the script: plain `swift test` on Command Line Tools cannot find the Testing framework, so it fails or runs zero tests.

```bash
scripts/test.sh
```

## Claude and Codex can read it too (MCP)

The MCP server is a separate program inside the app. The commands below use the path from a source build
(`~/Applications`). If you downloaded the app into your Applications folder, use
`/Applications/MacMonitor.app/Contents/MacOS/macmonitor-mcp` instead.

```
~/Applications/MacMonitor.app/Contents/MacOS/macmonitor-mcp
```

Register it with Claude Code:

```bash
claude mcp add -s user macmonitor -- ~/Applications/MacMonitor.app/Contents/MacOS/macmonitor-mcp
```

Register it with Codex:

```bash
codex mcp add macmonitor -- ~/Applications/MacMonitor.app/Contents/MacOS/macmonitor-mcp
```

It is a standard stdio MCP server, so any other MCP client works the same way: point it at that path.

Tools (all read only):

| Tool | What it gives |
|---|---|
| `get_snapshot` | Everything right now, grouped by area |
| `why_fan` | The fan headline and the readings behind it |
| `top_processes` | Top apps by cpu, memory, energy, gpu or disk |
| `get_history` | Points for one metric over the last N minutes |
| `list_metrics` | The metric names `get_history` accepts |
| `get_events` | The Events log for the last N hours |
| `get_sensors` | Every temperature sensor, with source and whether its label is proven |
| `get_hardware_health` | SSD health, battery health (three views), adapter and display |

The MCP server works even when the app is closed: it then takes a fresh live sample.
History tools need the app to have been running.

## What is skipped on purpose

These need root (an admin password) or would change hardware, so MacMonitor does not do them:

- `powermetrics` (needs root).
- Energy in watts for apps owned by root or other users. Those apps show CPU and Apple's
  energy impact score from `top` instead, marked "system".
- The motion sensor (accelerometer).
- Fan control or any write to the SMC. MacMonitor only reads.

## Privacy

- No serial numbers are shown in the app or returned by the MCP server.
- No network use. MacMonitor sends nothing anywhere.
- It never asks for or stores a password.
- The Wi-Fi network name is not shown (macOS needs Location access for it, and we do not ask).

## History

History lives in `~/Library/Application Support/MacMonitor/history.sqlite`.
It keeps 24 hours at full detail (one row a second) and per-minute summaries for 30 days.
It stays well under 150 MB (measured numbers in `docs/proof/db-size.txt`).

To clear it, use **Settings, History, Clear history**, or quit the app and delete that folder.

## Turn things off

Stop starting at login: turn off **Settings, Start at login**. Or, if it used the LaunchAgent fallback:

```bash
launchctl bootout gui/$(id -u)/com.macmonitor.app
rm ~/Library/LaunchAgents/com.macmonitor.app.plist
```

If it used SMAppService, you can also remove it in **System Settings, General, Login Items**.

Remove the MCP entry from Claude Code:

```bash
claude mcp remove -s user macmonitor
```

## CPU cost

MacMonitor is built not to heat the Mac it watches. Budget (100% = one core, 60 second average,
child processes such as `ps` and `top` included): 3% with only the menu bar, 15% with the window open.
Measure it:

```bash
defaults write com.macmonitor.app cpuLogPath /tmp/macmonitor-cpu.txt   # then restart the app
scripts/measure-cpu.sh "menu bar only" 60
```

Live motion (moving graph lines, rolling numbers, sliding bars, the spinning fan) runs in Core Animation,
so the app draws one frame a second and the system animates the rest.

## Screenshots without screen recording permission

```bash
~/Applications/MacMonitor.app/Contents/MacOS/MacMonitor --render-screenshots docs/screenshots --wait 130
```

This samples live for `--wait` seconds, then renders every page in dark and light to PNG.
It reads history but never writes it.

## How it works

- `Sources/CSensors`: small C wrappers that read the SMC, IOReport, HID sensors and NVMe SMART data.
- `Sources/MonitorCore`: the sampler, the data model, the history database, the fan explainer and the MCP server logic.
- `Sources/MacMonitor`: the SwiftUI menu bar app and window.
- `Sources/macmonitor-mcp`: the MCP server program.
- `docs/specs/`: the original design spec. `research/`: notes and small probe programs on which macOS data a normal user can read.
- `docs/FOLLOWUPS.md`: known issues.

## License

MIT. See [LICENSE](LICENSE).
