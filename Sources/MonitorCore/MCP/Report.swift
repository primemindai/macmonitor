import Foundation

/// Turns a Snapshot into plain JSON objects grouped by area, with units in the key names.
/// A missing reading is JSON null, and `not_available` says which areas had no source.
enum Report {
    /// Rounded to `places` (1000 = 3 decimals) and emitted as a decimal, so JSON shows 1.741, not 1.7410000000000001.
    static func v(_ x: Double?, _ places: Double = 1000) -> Any {
        guard let x, x.isFinite else { return NSNull() }
        let r = (x * places).rounded() / places
        let digits = max(0, Int(log10(places).rounded()))
        return NSDecimalNumber(string: String(format: "%.\(digits)f", r))
    }
    static func v(_ x: Int?) -> Any { x.map { $0 as Any } ?? NSNull() }
    static func v(_ x: UInt64?) -> Any { x.map { $0 as Any } ?? NSNull() }
    static func v(_ x: String?) -> Any { x.map { $0 as Any } ?? NSNull() }
    static func v(_ x: Bool?) -> Any { x.map { $0 as Any } ?? NSNull() }
    static func iso(_ d: Date?) -> Any { d.map { ISO8601DateFormatter().string(from: $0) } ?? NSNull() }

    static func snapshot(_ s: Snapshot, source: String) -> [String: Any] {
        var missing: [String] = []
        if s.cpu.totalPct == nil { missing.append("cpu: needs two samples, try again in a second") }
        if s.power.breakdown == nil { missing.append("power by part: IOReport not available") }
        if s.fans.isEmpty { missing.append("fans: SMC not available") }
        if s.gpu.utilPct == nil { missing.append("gpu utilization: IOAccelerator not available") }
        if s.battery == nil { missing.append("battery: not available") }
        if s.disks.smart == nil { missing.append("ssd smart: not available") }
        if s.wifi == nil { missing.append("wifi: radio off or not available") }
        if s.cpu.kernelTaskPct == nil { missing.append("kernel_task cpu: no fresh top reading (top runs every 15 s while the window is open, and in short bursts when the Mac heats up)") }
        let b = s.power.breakdown
        let c = s.cpu.clocks
        return [
            "source": source,
            "timestamp": iso(s.ts),
            "cpu": [
                "total_pct": v(s.cpu.totalPct), "p_cores_pct": v(s.cpu.pPct), "e_cores_pct": v(s.cpu.ePct),
                "per_core_pct": s.cpu.perCorePct.map { v($0) },
                "core_kinds": s.cpu.coreKinds.map(\.rawValue),
                "p_cluster0_mhz_runs_at": v(c?.pCluster0MHz), "p_cluster1_mhz_runs_at": v(c?.pCluster1MHz),
                "e_cluster_mhz_runs_at": v(c?.eClusterMHz),
                "per_core_mhz_asked_for": (c?.perCoreMHz ?? [:]).mapValues { v($0) },
                "load_avg": s.cpu.loadAvg.map { v($0) },
                "kernel_task_pct": v(s.cpu.kernelTaskPct),
            ] as [String: Any],
            "gpu": [
                "util_pct": v(s.gpu.utilPct), "renderer_pct": v(s.gpu.rendererPct), "tiler_pct": v(s.gpu.tilerPct),
                "mhz": v(s.gpu.mhz), "active_pct": v(s.gpu.activePct), "mem_in_use_bytes": v(s.gpu.inUseBytes),
                "mem_alloc_bytes": v(s.gpu.allocBytes), "resets": v(s.gpu.resets), "heat_cap_state": v(s.gpu.cltm),
            ] as [String: Any],
            "memory": [
                "total_bytes": v(s.memory.totalBytes), "used_bytes": v(s.memory.usedBytes), "app_bytes": v(s.memory.appBytes),
                "wired_bytes": v(s.memory.wiredBytes), "compressed_bytes": v(s.memory.compressedBytes),
                "compressed_holds_bytes": v(s.memory.compressedHoldsBytes), "cached_bytes": v(s.memory.cachedBytes),
                "free_bytes": v(s.memory.freeBytes), "swap_used_bytes": v(s.memory.swapUsed), "swap_total_bytes": v(s.memory.swapTotal),
                "pressure_level": v(s.memory.pressureLevel), "pressure_level_meaning": "1 normal, 2 warn, 4 critical",
                "memorystatus_free_pct": v(s.memory.memorystatusPercent),
                "pageins_per_s": v(s.memoryRates.pageinsPerSec), "swapins_per_s": v(s.memoryRates.swapinsPerSec),
                "swapouts_per_s": v(s.memoryRates.swapoutsPerSec),
            ] as [String: Any],
            "power": [
                "system_w": v(s.power.systemW), "adapter_in_w": v(s.power.adapterInW), "battery_w": v(s.power.batteryW),
                "wall_w": v(s.power.wallW), "cpu_w": v(b?.cpuW), "p_cluster0_w": v(b?.pCluster0W), "p_cluster1_w": v(b?.pCluster1W),
                "e_cluster_w": v(b?.eClusterW), "gpu_w": v(b?.gpuW), "gpu_energy_channel_w": v(b?.gpuAltW),
                "neural_engine_w": v(b?.aneW), "dram_w": v(b?.dramW), "memory_system_w": v(b?.memSystemW), "display_w": v(b?.displayW),
                "per_core_w": (b?.perCoreW ?? [:]).mapValues { v($0) },
                "note": "gpu_w is the IOReport GPU mJ channel; gpu_energy_channel_w is a second channel that reads lower.",
            ] as [String: Any],
            "thermal": [
                "thermal_state": v(s.thermal.state), "thermal_state_meaning": "0 nominal, 1 fair, 2 serious, 3 critical",
                "pressure": v(s.thermal.pressure), "pressure_meaning": "0 nominal, 1 moderate, 2 heavy, 3 trapping, 4 sleeping",
                "hottest_c": v(s.thermal.hottestC), "hottest_key": v(s.thermal.hottestKey),
                "hottest_reading_age_s": v(s.thermal.hottestHeldSeconds),
                "p_cores_c": v(s.thermal.cpuPC), "p_cores_reading_age_s": v(s.thermal.cpuPHeldSeconds), "e_cores_c": v(s.thermal.cpuEC), "gpu_c": v(s.thermal.gpuC),
                "ssd_c": v(s.thermal.ssdC), "battery_c": v(s.thermal.batteryC), "palm_rest_c": v(s.thermal.palmRestC),
                "ambient_c": v(s.thermal.ambientC),
                "label_note": "P core, E core and GPU sensor labels are best guesses from SMC key names.",
            ] as [String: Any],
            "fans": s.fans.map { f in
                [
                    "index": f.index, "actual_rpm": v(f.actualRPM), "target_rpm": v(f.targetRPM), "min_rpm": v(f.minRPM),
                    "max_rpm": v(f.maxRPM), "duty_0_to_1": v(f.duty), "state": v(f.state?.rawValue),
                ] as [String: Any]
            },
            "disks": [
                "read_bytes_per_s": v(s.disks.readBps), "write_bytes_per_s": v(s.disks.writeBps),
                "read_ops_per_s": v(s.disks.readOpsPerSec), "write_ops_per_s": v(s.disks.writeOpsPerSec),
                "read_latency_ms": v(s.disks.readLatencyMs), "write_latency_ms": v(s.disks.writeLatencyMs),
                "bytes_read_since_boot": v(s.disks.bytesReadSinceBoot), "bytes_written_since_boot": v(s.disks.bytesWrittenSinceBoot),
                "volumes": s.disks.volumes.map { vol in
                    ["name": vol.name, "path": vol.path, "total_bytes": vol.total, "free_bytes": vol.free,
                     "available_for_important_use_bytes": vol.importantFree, "purgeable_estimate_bytes": vol.purgeable] as [String: Any]
                },
            ] as [String: Any],
            "network": s.network.map { n in
                ["interface": n.name, "rx_bytes_per_s": v(n.rxBps), "tx_bytes_per_s": v(n.txBps), "link_bits_per_s": v(n.baud),
                 "rx_total_bytes": v(n.rxTotal), "tx_total_bytes": v(n.txTotal)] as [String: Any]
            },
            "wifi": s.wifi.map { w in
                ["rssi_dbm": v(w.rssi), "noise_dbm": v(w.noise), "tx_rate_mbps": v(w.txRateMbps), "channel": v(w.channel)] as [String: Any]
            } ?? NSNull(),
            "battery": s.battery.map { battery($0) } ?? NSNull(),
            "display": s.display.map { d in ["nits": v(d.nits), "brightness_0_to_1": v(d.brightness), "refresh_hz": v(d.refreshHz)] as [String: Any] } ?? NSNull(),
            "lid_angle_deg": v(s.lidAngle),
            "last_wake": iso(s.wakeTime),
            "top_processes": s.topProcesses.sorted { ($0.cpuPercent ?? 0) > ($1.cpuPercent ?? 0) }.prefix(10).map(process),
            "fan_explanation": s.fanExplanation.map(why) ?? NSNull(),
            "not_available": missing,
        ]
    }

    static func process(_ p: ProcSample) -> [String: Any] {
        [
            "pid": Int(p.pid), "name": p.name, "cpu_pct": v(p.cpuPercent), "memory_bytes": v(p.memBytes),
            "energy_w": v(p.energyW), "p_core_time_pct": v(p.pCorePercent), "gpu_pct": v(p.gpuPercent),
            "wakeups_per_s": v(p.wakeupsPerSec), "disk_read_bytes_per_s": v(p.diskReadBps),
            "disk_write_bytes_per_s": v(p.diskWriteBps), "energy_impact_score": v(p.energyImpact),
            "own_process": p.isOwn,
        ]
    }

    static func battery(_ b: BatteryInfo) -> [String: Any] {
        [
            "percent": v(b.percent), "is_charging": v(b.isCharging), "external_power": v(b.externalConnected),
            "cycle_count": v(b.cycleCount), "design_cycle_count": v(b.designCycles),
            "system_settings_max_capacity_pct": v(b.appleMaxCapacityPercent),
            "raw_capacity_vs_design_pct": v(b.rawHealthPercent),
            "macos_battery_flag": v(b.iopsHealth),
            "health_note": "Three views that can disagree: System Settings capacity (nominal / design), raw capacity vs design, and the macOS battery flag.",
            "design_capacity_mah": v(b.designCapacity), "raw_max_capacity_mah": v(b.rawMaxCapacity),
            "nominal_capacity_mah": v(b.nominalCapacity), "voltage_mv": v(b.voltageMV), "amperage_ma": v(b.amperageMA),
            "cell_voltages_mv": b.cellVoltagesMV, "cell_resistance": b.cellResistance, "temperature_c": v(b.temperatureC),
            "lifetime_max_temp_c": v(b.lifetimeMaxTempC), "lifetime_max_charge_ma": v(b.lifetimeMaxChargeMA),
            "lifetime_max_discharge_ma": v(b.lifetimeMaxDischargeMA), "wall_power_w": v(b.wallPowerW),
            "adapter_loss_w": v(b.adapterLossW), "adapter_name": v(b.adapterName), "adapter_watts": v(b.adapterWatts),
            "usb_pd_menu": b.pdMenu.map { ["voltage_mv": $0.voltageMV, "max_current_ma": $0.maxCurrentMA] },
        ]
    }

    static func why(_ x: FanExplanation) -> [String: Any] {
        [
            "headline": x.headline, "state": x.state.rawValue, "heading_to_rpm": v(x.headingToRPM),
            "source_block": x.sourceBlock, "source_share_pct": v(x.sourceShare, 10),
            "top_causes": x.topCauses.map { ["name": $0.name, "watts": v($0.watts), "gpu_pct": v($0.gpuPercent), "cpu_pct": v($0.cpuPercent)] as [String: Any] },
            "readings": x.readings.mapValues { v($0) }, "fallback_reason": v(x.fallbackReason),
            "note": "These are MacMonitor's rules built on the readings, not Apple's fan curve.",
        ]
    }

    static func smart(_ m: SMARTInfo) -> [String: Any] {
        [
            "temperature_c": v(m.tempC), "percent_used": v(m.percentUsed), "available_spare_pct": v(m.spare),
            "spare_threshold_pct": v(m.spareThreshold), "tb_written": v(m.tbWritten, 100), "tb_read": v(m.tbRead, 100),
            "power_on_hours": v(m.powerOnHours), "power_cycles": v(m.powerCycles), "unsafe_shutdowns": v(m.unsafeShutdowns),
            "media_errors": v(m.mediaErrors), "critical_warning": v(m.criticalWarning),
        ]
    }
}
