# MacMonitor known issues and follow-ups

Open items after the first build (2026-10-28). Pull requests welcome.

## Not yet proven on real hardware

- **First power sample after sleep.** IOReport intervals use `mach_absolute_time`, which stops during sleep. Each interval is also measured on `mach_continuous_time`, and a gap of over 1 s between the two drops that tick's power and clocks. This is proven with injected clocks only. After a real sleep, check history for a power spike in the first tick after the wake event.
- **Notification banners.** Alerts write Events rows. A banner shows only if notifications for MacMonitor are allowed in System Settings, Notifications, MacMonitor.

## Open notes (not fixed, by decision)

- **Disk image on a network share.** A disk image stored on a network share mounts as `MNT_LOCAL`, so reading its size can still block if that server dies. Rare. Possible fix: skip mounts whose source (`f_mntfromname`) is a disk image backed by a non-local file.
- **Upgrade from a build without the instance lock.** The one-copy check is an exclusive file lock (`~/Library/Application Support/MacMonitor/instance.lock`). An older build without the lock, still running during an upgrade, is not detected, so two copies can run until it quits. `scripts/bundle.sh` quits the old copy first.
- **Doc only.** The IOReport C header still calls the interval "wall time" (it is awake time), the continuous-time parameter has no doc, and `lastIntervalSeconds` in `IOReport.swift` has a duplicate doc line.
