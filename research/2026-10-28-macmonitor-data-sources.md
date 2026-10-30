# Mac monitor data sources: what a normal user can read (tested)

- Machine: MacBook Pro Mac16,8, Apple M4 Pro (10 P + 4 E cores), 48 GB, macOS 26.5.2 (build 25F84), Darwin 25.5.0.
- Tested on 2026-10-28 as a normal (admin, not root) user, no sudo, nothing installed, read only.
- The Mac was busy while we tested: load average about 10, P cores near 100%, fans at about 5,000 RPM, swap 18.6 of 19 GB used. So the sample values below are "hot and busy" values.
- The probe source code is in this `research/` folder (called "the research folder" below). The raw output files named below (`*.txt`, `battery_ioreg.plist`) are not included, because they were dumps from one person's Mac and held device serial numbers. Build and run a probe to get your own.

## TL;DR table

| Source | Data | Root? | Tested here | Sample value | Risk |
|---|---|---|---|---|---|
| AppleSMC user client (`IOConnectCallStructMethod` selector 2) | 3,246 keys: ~320 temps, 2 fans, ~78 power keys, battery, adapter, lid | No | Yes | Tp max 101.8 C, F0Ac 4,970 RPM, PSTR 60.2 W | Private, widely used (Stats, iStat) |
| IOHIDEventSystemClient (page 0xff00 usage 5) | 77 temp sensors with names: 14 PMU die, NAND, battery | No | Yes | "NAND CH0 temp" 63 C, "PMU tdie1" 80 C | Private, widely used |
| IOReport "Energy Model" (libIOReport) | Power per core, per cluster, GPU, ANE, DRAM, display, media | No | Yes | CPU 23.7 W, GPU 1.7 W, DRAM 2.2 W | Private, widely used (macmon, asitop) |
| IOReport "CPU Stats" + pmgr `voltage-states*-sram` | Per-core and per-cluster frequency residency, real MHz | No | Yes | P cluster 90% at 3,756 MHz | Private, widely used |
| IOReport "GPU Stats" | GPU freq states, thermal (CLTM) cap, power target, throttle counters | No | Yes | GPU 64% active at 338 MHz, CLTM none | Private |
| IOReport other groups (10,846 channels) | Screen nits, Wi-Fi chip temp, SSD interrupts, NVMe throttle, sensors on/off | No | Yes | Screen 381.8 nits, Wi-Fi chip 54 C | Private, fragile names |
| IOAccelerator `PerformanceStatistics` | GPU Device / Renderer / Tiler %, GPU memory | No | Yes | Device 41%, in use 1.03 GB | Private but stable for years |
| AGXDeviceUserClient `AppUsage` | GPU time per process, even root ones | No | Yes | WindowServer 35% GPU | Private |
| `host_processor_info` | Ticks per core (user/sys/idle) | No | Yes | P cores ~65% busy | Public |
| `host_statistics64` + sysctl | Wired, compressed, swap, pressure, page-ins | No | Yes | 66.9 GB squeezed into 16.2 GB | Public |
| `proc_pid_rusage` V6 | Energy, P vs E time, wakeups, disk bytes per process | No (own processes only) | Yes | Python 1.46 W, 184 MB/s read | Public (undocumented fields) |
| `/usr/bin/top`, `/bin/ps` (setuid root) | CPU and POWER for root processes too | No (they are setuid) | Yes | kernel_task 35.5% | Public tools, parse text |
| NVMe SMART (`kIONVMeSMARTUserClientTypeID`) | SSD temp, wear %, TB written, hours | No | Yes | 25% used, 111.7 TB written | Public SDK header |
| IOBlockStorageDriver `Statistics` | Bytes, ops, time per disk | No | Yes | 24.3 TB written since boot | Public |
| AppleSmartBattery (ioreg) | Cycles, health, cell volts, adapter, wall power | No | Yes | 179 cycles, 81.6% raw health | Private keys, stable |
| IOPS (`IOPSCopyPowerSourcesInfo`) | Battery state, "Check Battery" flag, adapter | No | Yes | 96W adapter, "Check Battery" | Public |
| sysctl NET_RT_IFLIST2 | 64-bit bytes per interface, link speed | No | Yes | en8 1 Gbps | Public |
| CoreWLAN | RSSI, noise, rate, channel | No (SSID needs Location) | API tested, Wi-Fi was off | all zero (radio off) | Public |
| HID lid angle (page 0x20 usage 0x8A) | Lid angle in degrees | No | Yes | 104 degrees | Private, fragile |
| HID ambient light (page 0xff00 usage 4) | Ambient light level | No | Yes | 205 | Private |
| DisplayServices / CGDisplay | Brightness, refresh rate, EDR headroom | No | Yes | 0.81, 120 Hz, EDR 16x | Mix |
| `ProcessInfo.thermalState`, notify thermal pressure | Thermal level | No | Yes | 1 (fair / moderate) | Public |
| `zprint` | Kernel zone memory | No | Yes | works | Public tool |
| `powermetrics` | Everything above in one tool | **Yes** | Yes, refused | "must be invoked as the superuser" | n/a |

## Wow list (things common monitor apps do not show)

1. **SSD wear and lifetime writes.** NVMe SMART says 25% used, 111.7 TB written, 120.6 TB read, 2,424 power-on hours, 12 unsafe shutdowns, SSD at 64 C. No root.
2. **Why the SSD is wearing out.** Memory stats show 66.9 GB of app memory squeezed into 16.2 GB (about 4x), swap 18.2 of 19 GB, 9.4 million swap-outs. IOReport shows the SSD controller ("ans") firing about 10,400 interrupts per second. We can tie swap to SSD wear on one screen.
3. **Real per-core power in watts.** IOReport "Energy Model" gives each of the 14 cores its own power (each P core about 2.3 W under load, each E core about 0.13 W), plus GPU, ANE, DRAM, display, video encoder, image processor.
4. **Real cluster clock vs asked-for clock.** Each P core "asks" for its top state (4,512 MHz, `V18P0`), but the P cluster power manager (`PCPM`) really runs at 3,756 MHz (`V12P6`) 90% of the time under all-core load. Most apps show only one number.
5. **GPU time per app, including WindowServer.** `AGXDeviceUserClient` `AppUsage` gives `accumulatedGPUTime` in nanoseconds per process. WindowServer 35.1%, Claude Helper 5.9%. It adds up to the 41% device number. Activity Monitor shows this only as a column you must turn on, and menu bar apps rarely do.
6. **Per-process energy and P vs E core time.** `ri_energy_nj` and `ri_user_ptime` / `ri_system_ptime` show each app's real energy (mW) and how much of its time ran on P cores.
7. **Wall power and adapter loss.** AppleSmartBattery `PowerTelemetryData` shows `SystemPowerIn` 53.4 W, `AdapterEfficiencyLoss` 1.5 W, input 20.2 V at 2.64 A, plus lifetime energy counters.
8. **Battery life story.** Raw max 5,099 mAh vs design 6,249 mAh (81.6%), three cell voltages (4,281 / 4,282 / 4,282 mV), lifetime max temp 41 C, max discharge 8.7 A, chemistry ID, macOS "Check Battery" flag.
9. **Adapter identity.** "96W USB-C Power Adapter", serial, firmware 01090058, and the full USB-PD menu (5 V / 9 V / 15 V / 20 V with max current each).
10. **Screen light output in real units.** IOReport "backlight report" gives 381.8 nits (`MilliNits value` 381794) and backlight current 3,199 microamps.
11. **Lid angle.** 104 degrees, live, from the hinge sensor.
12. **Wi-Fi chip temperature and power backoff.** IOReport "TVPM Slice 0": chip 54 C, transmit power backoff in dB, and a temperature histogram, with no Location permission.
13. **Thermal caps on the GPU.** "CLTM-induced GPU Performance States" shows if heat is capping the GPU (now `NO_CLTM`), and "PPM Target as % of Max GPU Power" (now 100%).
14. **Root process cost without root.** `/usr/bin/top` is setuid root, so we can parse it for kernel_task (35.5% CPU, a throttle sign) and WindowServer power.
15. **Fan duty and fan target.** SMC gives target RPM, actual RPM and duty (`F0Dc` 0.386), so we can show "ramping up / down, toward X RPM".

## Why is the fan on?

### What to read

- **Fans (SMC):** `FNum` (2), `F0Ac` / `F1Ac` actual RPM, `F0Tg` / `F1Tg` target RPM, `F0Mn` 2,317, `F0Mx` 7,826, `F0Md` mode (0 = auto), `F0Dc` duty (0 to 1), `Ftst` (0 = no forced test or manual mode).
- **Heat (SMC):** hottest of the `Tp*` keys (P cores), `Te*` (E cores), `Tg*` (GPU). `TCMz` looks like an "all CPU max" key (it matched the hottest `Tp` key exactly in one snapshot, and was close in another).
- **Power (IOReport Energy Model):** P cluster 0, P cluster 1, E cluster, GPU, ANE, DRAM + `AMCC` + `DCS` (memory system).
- **Power (SMC):** `PSTR` system total, `PDTR` power from the adapter, `PPBR` battery power.
- **Who (per process):** `ri_energy_nj` deltas (own processes), GPU `accumulatedGPUTime` deltas (all processes), `top` POWER column (root processes).
- **Pressure:** `ProcessInfo.thermalState`, notify `com.apple.system.thermalpressurelevel`.

### What we saw (8 second watch, `fan_watch`)

- Fan 0: actual 4,654 then 4,625; target 4,654 then 4,590. Target fell about 9 RPM per second.
- Fan 1: about 5,000 RPM, also slowly falling.
- System power 41 to 55 W. Hottest P core 95 to 101 C. GPU max 71 C.
- Thermal state "fair", pressure "moderate".
- One small finding: on AC power, `PSTR` equals the `PDTR` value from about one second earlier, so `PSTR` lags.

### Rule set

1. **Fan state.**
   - `off` if `F0Ac` < 100.
   - `ramping up` if `F0Tg - F0Ac` > 50 RPM.
   - `ramping down` if `F0Ac - F0Tg` > 50 RPM, or if target has dropped over the last 10 s.
   - `steady` otherwise.
   - Show "heading to `F0Tg` RPM". Show fan load as `(F0Ac - F0Mn) / (F0Mx - F0Mn)`.
2. **Heat source.** The fan follows heat, and heat follows power with a lag of tens of seconds. So use power averaged over the last 30 to 60 s, not the last second.
   - Share for each block = block power / sum of (P0 + P1 + E + GPU + ANE + DRAM + AMCC + DCS).
   - Name the biggest block: "P cores 85%" or "GPU 60%".
3. **Who caused it.** Rank processes by energy over the same 30 to 60 s window.
   - CPU heat: `ri_energy_nj` delta (own processes), plus `top` POWER for root processes.
   - GPU heat: `accumulatedGPUTime` delta.
4. **Headline.** "Fan at 4,600 RPM and slowly falling, because the P cores used about 23 W for the last minute. Top cause: com.apple.Virtualization (1.5 W), Python (1.5 W)."
5. **Not CPU or GPU?** If CPU + GPU power is low but the fan is on, check: charging power (`ChargingCurrent`), SSD temp (SMART, NAND HID sensor), ambient or palm rest temps (`Ts0P`, `Ts1P`), lid angle (closed lid in clamshell mode runs hotter), and room heat.
6. **Throttle warning.** Warn if thermal pressure is 2 or more, or the GPU CLTM state is not `NO_CLTM`, or kernel_task CPU is high, or the P cluster `PCPM` frequency is far under the per-core asked-for frequency for a long time.

Note: we do not know Apple's exact fan curve. The rules above are our design, built on the readings, not Apple's formula.

## Details per source

### 1. Temperatures

**SMC (AppleSMC)**
- Probe: `smc_dump.c` (all keys), `fan_watch.c` (1 Hz watch). Full dump: `smc_all.txt`.
- API: `IOServiceOpen("AppleSMC")`, `IOConnectCallStructMethod(conn, 2, ...)` with sub-commands 5 (read), 8 (key by index), 9 (key info). Key count from `#KEY`.
- Root: no. Works on M4 Pro: yes.
- 3,246 keys; 321 start with `T`; 140 keys of all kinds return a read error (normal, they are write-only or locked).
- Temps are type `flt ` (float). A few are `ioft` (fixed point / 65536).
- Cost: about 0.56 ms per key (key info + read). A full sweep takes 1.7 s. Read only a chosen list of about 20 to 40 keys, and cache key info to halve the calls.
- **Integers are little-endian on Apple Silicon.** Checked: `B0AV` reads 11,314 as big-endian, but 12,844 as little-endian, which matches battery voltage 12,845 mV. `B0CT` gives 179 cycles only if read little-endian.
- Labels (the "Proven" ones matched another source; the others are best guess, not proven):

| Keys | Sample | Label |
|---|---|---|
| `Tp00` to `Tp2X`, `Tpx0` to `TpxD` | 72 to 101.8 C | P core cluster area (best guess) |
| `Te04` to `Te0T`, `Tex0` to `Tex3` | 72 to 84 C | E cores (best guess) |
| `Tg04` to `Tg1l` | 67 to 75 C | GPU (best guess) |
| `TCMz`, `TCMb` | 101.8, 89.4 C | CPU max style summary (`TCMz` matched the hottest Tp key once) |
| `TB0T`, `TB1T`, `TB2T`, `TG0B`, `TG0C`, `TG0H`, `TG0V`, `TG1B`, `TG2B` | 35.0 to 36.2 C | Battery. **Proven**: exact match with HID "gas gauge battery" values |
| `TR0Z` | 51.82 C | **Proven**: exact match with HID "PMU tcal" |
| `TH0a`, `TH0b`, `TH0x` | 56 to 56.7 C | SSD area (best guess; SMART said 64 C) |
| `Ts0P`, `Ts1P` | 33.8, 30.9 C | Palm rest (best guess) |
| `TaLP`, `TaRF`, `TaLT`, `TaRT`, `TaLW`, `TaRW` | 35 to 58 C | Air flow left / right (best guess) |
| `TW0P` | 60 C | Wi-Fi area (best guess) |
| `TVA0`, `mxA0` | 24.8 C | Ambient (best guess, low value fits) |
| `TPD*`, `TUD*`, `TRD*`, `TD**`, `TV**` | 31 to 92 C | Unknown die and regulator sensors |
| `Ta00`/`Ta01` etc. | 0 or 8.3 | Not real temps |

**HID sensors (IOHIDEventSystemClient)**
- Probe: `hid_sensors.c`. Output: `hid_temps.txt`.
- API: `IOHIDEventSystemClientCreate`, match `PrimaryUsagePage 0xff00`, `PrimaryUsage 5`, `IOHIDServiceClientCopyEvent(type 15)`, `IOHIDEventGetFloatValue(type << 16)`.
- Root: no. Works: yes. Cost: 57 to 135 ms for all 77 (first call slower).
- Names: "PMU tdie1" to "PMU tdie14" (69 to 80 C), "PMU tcal" (51.8 C), "NAND CH0 temp" (63 C), "gas gauge battery" (35 to 36.2 C), "PMU tdev1-8" (junk, about -9,200).
- Each name shows up 3 times (3 PMUs or 3 paths). Dedupe by name plus service ID.
- **Compare:** HID has fewer, named sensors and reads cooler (die max 80 C). SMC has far more sensors and shows the true hot spots (101.8 C). Use SMC for "hottest", HID for "SSD (NAND)" and names.
- Same API with page 0xff08 (voltage, current) returned nonsense with event type 25. Not decoded. Treat as not working.

### 2. Fans
- Probe: `fan_watch.c`, and `smc_dump F`.
- Root: no. Works: yes.
- Live: `F0Ac` 4,969.6, `F0Tg` 4,951, `F1Ac` 5,344.9, `F1Tg` 5,347, `F0Mn`/`F1Mn` 2,317, `F0Mx`/`F1Mx` 7,826, `F0Md`/`F1Md` 0, `F0Dc` 0.386, `F1Dc` 0.432, `FNum` 2, `Ftst` 0.
- Not sure: `F0St` 5, `F0Fb` 1, `F0Fc` 4, `F0CR` 38,400, `FOff` 1, `Fpds` 3, `MSXA` = "F1Ac" (text pointing at a fan key). Show raw, do not label.
- Fan writes are possible on some Macs but we never tried. Read only.

### 3. Power

**IOReport (libIOReport)**
- Probes: `ioreport_list.c` (lists all 10,846 channels to `ioreport_channels.txt`), `ioreport_sample.c` (subscribe, two samples, delta). Shared header: `ioreport_common.h`. Link with `-lIOReport` (the dylib lives in the dyld cache, not on disk).
- Root: no. Works: yes. Cost: subscribe about 2 ms, one sample 4.6 to 11 ms.
- "Energy Model" (units mJ, a few uJ and nJ). Power = energy delta / seconds. Sample over 1 s under load:
  - P cores: `PACC0_CPU0`..`CPU4` and `PACC1_CPU0`..`CPU4`, each about 2,260 to 2,420 mW.
  - E cores: `EACC_CPU0`..`CPU3`, 110 to 143 mW.
  - Clusters: `PACC0_CPU` 11,752, `PACC1_CPU` 11,419, `EACC_CPU` 497, total `CPU Energy` 23,668 mW.
  - `GPU` 1,746 mW (and `GPU Energy` in nJ said 791 mW; the two GPU numbers differ, pick one and label it).
  - `ANE` 0 (idle), `DRAM` 2,165, `AMCC` 2,689, `DCS` 2,885, `DISP` 253, `DISPEXT` 14, `AVE` (video encoder) 7, `ISP` (camera) 7, `MSR` 7, `AFR` 111 mW.
  - The table lists 6 core slots per P cluster but only 5 have data (binned chip).
  - `ECPUDTL*` / `PCPUDTL*` channels exist too (unknown meaning, not decoded).
- Media engine: only the encoder (`AVE`) has an energy channel. No decoder channel was found. AppleAVD in ioreg has no stats.

**SMC power keys** (watts, `flt`): `PSTR` 60.17 system total, `PDTR` 55.83 adapter in, `PPBR` 0.86 battery, `PHPC` 35.9, `PHPS` 32.2, `PPMC` 17.2, `PPSC` 18.2, `PMVC` 44.2, `PZC0` 32.2, `PZC1` 32.7, `PTHS` 40.4. Only `PSTR`, `PDTR`, `PPBR` are labeled with any confidence; the rest are unknown.

### 4. GPU
- `ioreg -r -c IOAccelerator` `PerformanceStatistics`: `Device Utilization %` 41, `Renderer Utilization %` 41, `Tiler Utilization %` 15, `In use system memory` 1.03 GB, `Alloc system memory` 3.99 GB, `recoveryCount` 0 (GPU resets). Also `gpu-core-count` 20. Root: no. Cost: about 120 ms via the `ioreg` tool; much less with `IORegistryEntryCreateCFProperty` in-process (not timed).
- GPU frequency: IOReport "GPU Stats / GPU Performance States" (`GPUPH`): `OFF` 35.6%, `P1` 64.4%. Active % = 100 - OFF. MHz from pmgr `voltage-states9-sram`: P1 = 338 MHz. Note: that table is not in order (1,312 then 1,242). Check it against `powermetrics` (needs sudo) before trusting top states.
- Throttle: `CLTM-induced GPU Performance States` = `NO_CLTM` 100%; `PPM Target as % of Max GPU Power` = 100%; `GPU Throttler Counters` (counts, absolute).
- IOReport "GPU Stats / Temperature" has `Tg1a`, `Tg5a`, `Tg7a` Latest / Min / Max values. They read zero in our window. Not tested under GPU load.

### 5. CPU
- `host_processor_info(PROCESSOR_CPU_LOAD_INFO)`: 14 CPUs. cpu0 to cpu3 are E, cpu4 to cpu13 are P (matches `hw.perflevel1.logicalcpu` 4 and `hw.perflevel0.logicalcpu` 10). Cost 0.055 ms. Probe: `sys_probe.swift`.
- `hw.perflevel0.l2cachesize` 16 MB, `hw.perflevel1.l2cachesize` 4 MB.
- Load average via `getloadavg`: 9.5, 9.9, 9.9.
- **Real MHz:** IOReport "CPU Stats". State names look like `V18P0`. The number after V is the index into the pmgr table. Tables (kHz on M4, divide by 1,000):
  - E cores: `voltage-states1-sram`: 1,020 / 1,404 / 1,788 / 2,112 / 2,352 / 2,532 / 2,592 MHz.
  - P cores: `voltage-states5-sram`: 1,260 up to 4,512 MHz (19 steps).
  - MHz = sum(residency x freq) / sum(non-idle residency).
  - "CPU Core Performance States" (per core, `PCPU000` etc.) showed `V18P0` (4,512 MHz) 95%. "CPU Complex Performance States" `PCPM` showed `V12P6` (3,756 MHz) 90%. We think per-core is the requested speed and `PCPM` / `ECPM` is what the cluster really runs. Not proven. Check once against `sudo powermetrics`.
- kernel_task CPU: not readable by our process (pid 0 is denied). `/usr/bin/top -l 2 -s 1 -stats pid,command,cpu,power` works (top is setuid root): kernel_task 35.5%.
- Seen once, not explained: tick counters said P cores about 65% busy, IOReport said about 96% non-idle. The samples were a minute apart, and a Linux VM was running. Do not ship a claim about this until tested side by side.

### 6. Thermal pressure and throttling
- `ProcessInfo.processInfo.thermalState` = 1 (fair). Public. Has a change notification.
- `notify_register_check("com.apple.system.thermalpressurelevel")` + `notify_get_state` = 1 (moderate). Scale 0 nominal, 1 moderate, 2 heavy, 3 trapping, 4 sleeping.
- `pmset -g therm`: "No thermal warning level has been recorded". `pmset -g thermlog` printed nothing in 3 s (it only prints on changes).
- IOReport "PPM Stats" (power manager): `CPMS Power Reduction` (SysInst / Sys100ms / Sys1s), `CPMS Ferocity`, `Droop Controller`. All 0% now. These look like CPU power capping meters. Not tested under real throttling.
- IOReport "NVMe / Time weighted throttle statistics" and "NVMe / BW Limits" (all tiers 100%): SSD throttle.
- No clear "CLPC" group name was found in the channel list.
- SMC keys `mlT0` 85, `mlT1` 100, `mxT0` 85, `mlMH` 86 look like temperature limits. Not proven.

### 7. Memory
- `host_statistics64(HOST_VM_INFO64)`, cost 0.005 ms. Sample: free 0.25 GB, active 13.4, inactive 13.3, wired 4.1, compressor 16.2 GB holding 66.9 GB, purgeable 0.12, file-backed 8.5, anonymous 18.2 GB.
- Activity Monitor style: App = internal - purgeable = 18.1 GB, Cached = external + purgeable = 8.6 GB.
- Counters: pageins 597 M, pageouts 4.5 M, swapins 7.0 M, swapouts 9.5 M, compressions 1.97 B.
- `vm.swapusage`: 19.0 GB total, 18.2 GB used.
- `kern.memorystatus_vm_pressure_level` 1 (normal; 2 warn, 4 critical). `kern.memorystatus_level` 56 (percent free, same idea as `memory_pressure` which said 57%). `vm.compressor_bytes_used` 15.6 GB.

### 8. Per process
- Probe: `proc_rusage.c` (1 s window), `proc_taskinfo_test.c` (access test), `gpu_per_process.py` (GPU).
- `proc_pid_rusage(pid, RUSAGE_INFO_V6)`: works for our own 481 processes. **Denied** for all 131 root processes and 71 other-user processes (pid 0, 1, WindowServer, opendirectoryd). Snapshot of all processes costs 3.5 ms.
- Useful fields: `ri_energy_nj` (energy), `ri_penergy_nj` (P core energy), `ri_user_ptime` + `ri_system_ptime` (P core time; E time = total - P), `ri_interrupt_wkups`, `ri_pkg_idle_wkups`, `ri_diskio_bytesread` / `written`, `ri_phys_footprint`, `ri_instructions`, `ri_cycles`, `ri_cpu_time_qos_*`. Times are in mach ticks; multiply by timebase (125/3 on Apple Silicon).
- `ri_billed_energy` was 0 for our process. Do not rely on it.
- Sample (1 s): com.apple.Virtualization 67.8% CPU, 1.5 W, 48 MB written; Python 39.4%, 1.46 W, 184 MB read; com.docker.backend 4,583 interrupt wakeups per second.
- Same rule for `PROC_PIDTASKINFO` (context switches `pti_csw`, syscalls, faults): own processes only.
- Root processes: parse `/usr/bin/top` or `/bin/ps` (both setuid root).
- **GPU per process:** `AGXDeviceUserClient` property `IOUserClientCreator` ("pid 396, WindowServer") and `AppUsage` array with `accumulatedGPUTime` (ns). Works for root processes too. 59 clients, about 23 ms via `ioreg`. Sample: WindowServer 35.1%, Claude Helper 5.9%.

### 9. Disks
- `URLResourceValues` (probe `io_probe.swift`, 48 ms): "Macintosh HD" 994.7 GB total, 25.3 GB free, 27.0 GB for important use, 13.3 GB for opportunistic use. The disk is nearly full.
- `IOBlockStorageDriver` `Statistics`: bytes, operations, total time, errors, retries for read and write. Since boot: 12.2 TB read, 24.3 TB written, 0 errors. Latency fields are 0 on this SSD. Average latency = total time / operations (ns).
- **NVMe SMART:** probe `nvme_smart.c`. API: `IOCreatePlugInInterfaceForService(kIONVMeSMARTUserClientTypeID)`, then `SMARTReadData` from `NVMeSMARTLibExternal.h` (public SDK header). Matches service `IONVMeBlockStorageDevice`. Root: no. Cost 3.9 ms.
  - temperature 64 C, percentage used 25%, available spare 100% (threshold 99%), data units written 218,243,862 (111.74 TB), read 120.57 TB, power cycles 199, power-on hours 2,424, unsafe shutdowns 12, media errors 0, critical warning 0.
- `smartctl`: not installed (we did not install it). Not needed.
- `diskutil info /`: "SMART Status: Verified".

### 10. Battery and power adapter
- `ioreg -r -c AppleSmartBattery -a` (saved as `battery_ioreg.plist`):
  - `CycleCount` 179, `DesignCapacity` 6,249, `AppleRawMaxCapacity` 5,099 (81.6%), `NominalChargeCapacity` 5,251, `AppleRawCurrentCapacity` 5,043.
  - `Voltage` 12,845 mV, `InstantAmperage` 0, `Temperature` 3,094 (30.94 C), `VirtualTemperature` 3,619, `IsCharging` false, `FullyCharged` true.
  - `BatteryData`: `CellVoltage` [4281, 4282, 4282], `Qmax` [5992, 5971, 5993], `WeightedRa` [76, 73, 75] (cell resistance), `ChemID` 29795, `DailyMaxSoc` / `DailyMinSoc`, `LifetimeData` (max temp 41 C, min 9 C, max charge 6.76 A, max discharge 8.67 A, max pack voltage 13.3 V).
  - `ChargerData`: `NotChargingReason` 4194305, `ChargingVoltage` 4,332, `TimeChargingThermallyLimited` 0.
  - `PowerTelemetryData`: `SystemPowerIn` 53,394 mW, `SystemVoltageIn` 20,209 mV, `SystemCurrentIn` 2,642 mA, `AdapterEfficiencyLoss` 1,504 mW, `WallEnergyEstimate`, lifetime accumulators.
  - `AdapterDetails`: "96W USB-C Power Adapter", `Watts` 94, serial, `FwVersion`, `UsbHvcMenu` (PD voltage/current menu).
  - `PortControllerInfo`: attach count 23 and USB-C port state.
- IOPS (`IOPSCopyPowerSourcesInfo`, `IOPSCopyExternalPowerAdapterDetails`): public. `BatteryHealth` "Check Battery", `DesignCycleCount` 1000, adapter same as above.
- SMC also has battery keys (`B0AV`, `B0CT`, `B0FC`, `BMDN` "bq40z651", `BMSN` serial) and adapter keys (`D4in` "96W USB-C Power Adapter", `D4is` serial, `D4im` "Apple Inc.").
- IOReport "Battery" group: `BatteryCycleCount` 179.

### 11. Network
- `sysctl` `NET_RT_IFLIST2` gives 64-bit counters (`if_msghdr2`). Cost 0.38 ms. en8 (USB Ethernet "AX88179B") 1 Gbps baud; lo0 223 KB/s each way. Use this, not `getifaddrs` (32-bit counters wrap at 4 GB).
- CoreWLAN: API works, but Wi-Fi power was off during the test, so RSSI, noise, rate and channel were 0. SSID returned nil (needs Location permission for an app). **Not tested with Wi-Fi on.**
- IOReport has deep Wi-Fi groups that need no Location: "Interface en0 / RSSI", "Noise Floor", "Link Rate", "Phy Mode", "Average CCA", "QBSS Channel Utilitzation" (Apple's spelling), plus "TVPM Slice 0" chip temperature (54 C) and transmit power backoff. Values under live Wi-Fi: **not tested**.
- Thunderbolt: `IOThunderboltSwitch` has "Current Link Speed / Width". Nothing was plugged in, so all 0.
- USB: `IOUSBHostDevice` `UsbPowerSinkAllocation` (mA): headphone adapter 300, Ethernet adapter 184.

### 12. Other surprising readable data
- **Lid angle:** `hid_motion_lid.c`. IOHIDManager, match page 0x20 usage 0x8A (Apple product 0x8104), `IOHIDDeviceGetReport(feature, id 1)`: bytes 01 68 00, angle 104 degrees. Root: no. Private, may change.
- **Accelerometer:** device (page 0xff00 usage 3) opens, but sent 0 reports in 1 s. Public projects turn it on by setting a "ReportInterval" property, which changes the driver and they run it with sudo. We did not try (read-only rule). Treat as **needs root**.
- **Ambient light:** HID page 0xff00 usage 4, event type 12: 205. IOReport "AOP / AOP Sensors": `als` ON, `accel` ON, `gyro` OFF.
- **Display:** `CGDisplayCopyDisplayMode`: 3024x1964 at 120 Hz. `NSScreen.maximumFramesPerSecond` 120. EDR headroom now 1.0, potential 16.0. `DisplayServicesGetBrightness` (private, via `dlopen`) 0.809. IOReport "backlight report": 381.8 nits, 3,199 uA. Probe: `display_probe.swift`.
- **Lid closed:** SMC `MSLD` 0 (open).
- **Interrupts per device:** IOReport "Interrupt Statistics (by index)" counts and time per interrupt source: SSD ("ans") 10,413 per second.
- **Sleep and wake:** `pmset -g stats`: 510 sleeps, 501 dark wakes, 44 user wakes. `kern.boottime` 2026-10-10 15:15 UTC, `kern.waketime` 2026-10-28 05:51 UTC. `pmset -g log` has full history; `pmset -g assertions` shows who blocks sleep (sharingd "Handoff").
- **Kernel zones:** `zprint` works without root.
- **Trackpad power state times**, **audio codec states**, **camera (ISP) events**, **PCIe bandwidth** (IOReport "Bandwidth"): channels exist. Bandwidth read 0 in our window. Not decoded.
- **Memory bandwidth:** "AMC Stats / Perf Counters" and "PMP / DCS BW" exist but gave no usable numbers with our simple reader. Not tested further.
- **Bluetooth device batteries:** no Bluetooth device with a battery was connected. **Not tested.** (Expected place: ioreg `BatteryPercent` on `AppleDeviceManagementHIDEventService`.)
- **System-wide context switch and syscall rates:** not found without root. Per process works for own processes only.

## Probe files (research folder)

- `smc_dump.c`: all SMC keys, or `-k KEY`, or by first letter. Output `smc_all.txt`.
- `fan_watch.c`: 1 Hz fans, power, hottest sensors.
- `hid_sensors.c`: HID temps (default), other pages by args. Outputs `hid_temps.txt`, `hid_volts.txt`, `hid_amps.txt`.
- `ioreport_common.h`, `ioreport_list.c`, `ioreport_sample.c`: IOReport. `ABS=1` env prints raw values instead of deltas. Outputs `ioreport_channels.txt`, `sample_power.txt`.
- `sys_probe.swift`: thermal state, notify pressure, ticks per core, memory, swap, boot and wake time. Output `sample_sys.txt`.
- `proc_rusage.c`, `proc_taskinfo_test.c`: per process. Output `sample_proc.txt`.
- `gpu_per_process.py`: GPU time per process.
- `nvme_smart.c`: SSD SMART. Output `sample_smart.txt`.
- `io_probe.swift`: volumes, IOPS, CoreWLAN, network. Output `sample_io.txt`.
- `hid_motion_lid.c`: lid angle and accelerometer test. Output `sample_lid.txt`.
- `display_probe.swift`: displays and brightness.
- `battery_ioreg.plist`: full battery dump (not included; run `ioreg -r -c AppleSmartBattery -a`).
- Build lines are at the top of each file. Everything builds with Command Line Tools only (`clang`, `swiftc`).

## Needs root / not available

- `powermetrics`: needs root (tested: "must be invoked as the superuser").
- `proc_pid_rusage` and `PROC_PIDTASKINFO` on root or other-user processes: denied (tested on pid 0, 1, 364, 396). Work-around: parse setuid `/usr/bin/top` or `/bin/ps`.
- kernel_task stats directly: denied. Use `top`.
- Accelerometer data stream: needs a driver property change; public tools use sudo. Not tried.
- Fan control or any SMC write: not tried (read-only rule), and it needs root on Apple Silicon per common knowledge.
- Wi-Fi SSID / BSSID from an app: needs Location permission (not root).
- System-wide context switch rate: no source found without root.

## Not tested

- CoreWLAN live values (Wi-Fi was off).
- IOReport Wi-Fi link values with Wi-Fi on.
- Bluetooth device battery levels (none connected).
- Thunderbolt link speed (nothing connected).
- GPU temperature IOReport channels under GPU load.
- ANE power under load (it was idle: 0 mW).
- Whether per-core `V18P0` or cluster `PCPM` is the true clock (needs one `sudo powermetrics` run by the owner to compare).
- HID voltage and current sensors (page 0xff08): our reads gave junk.
