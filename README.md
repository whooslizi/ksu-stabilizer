# KSU Stabilizer

A KernelSU module that keeps the root manager app responsive, and force-closes it if it hangs.

Supported managers: KernelSU (`me.weishu.kernelsu`), KernelSU Next (`com.rifsxd.ksunext`), SukiSU Ultra (`com.sukisu.ultra`).
**KernelSU only**: the installer refuses Magisk/APatch.

## What it does

At boot (once):
- Raises socket buffer limits (`net.core.rmem/wmem_*`, `net.unix.max_dgram_qlen`, `netdev_max_backlog`). Values are only raised, never lowered.
- Adds a routing rule so `127.0.0.0/8` and `::1` always use the `local` table, so a VPN or firewall can't misroute localhost traffic.

Every 15 seconds:
- **Boost**: gives `ksud` priority nice -10 and puts it in the `top-app` CPU group. Gives the manager app nice -6. Applies the boost again whenever Android resets it, e.g. after you reopen the app.
- **Keep in RAM**: lowers the manager's `oom_score_adj` back to 0 whenever Android raises it, so the memory killer treats it like the app on screen. At boot, the manager is also exempted from Doze, background limits and app standby.
- **Hang watchdog**: force-closes the manager (`am force-stop`) if its main thread is stuck in a kernel call for 2 checks in a row (15–30 s), or if Android shows "Application Not Responding" for it. `ksud` is never killed.

## Install

Download the zip from [Releases](../../releases) (or a build's Artifacts), then install it from the KernelSU manager's Module tab and reboot.
Don't install GitHub's "Source code (zip)", and don't zip the folder with Finder's "Compress": both put the files inside a folder, and KernelSU fails with *"specified file not found in archive"*. `module.prop` must be at the top level of the zip.

## Build

GitHub Actions builds the zip on every push to the default branch. When `version=` in `module.prop` is new, it also publishes a release tagged with that version (e.g. `v1.1`). To release, bump `version` and `versionCode`, then push.

Local build:
```sh
zip -r ksu_stabilizer.zip module.prop service.sh customize.sh uninstall.sh META-INF -x '*.DS_Store'
```

## Settings

Edit the values at the top of `service.sh`:

| Variable | Default | Meaning |
|---|---|---|
| `POLL` | `15` | Seconds between checks |
| `HANG_TICKS` | `2` | Stuck checks in a row before force-closing |
| `KSUD_NICE` | `-10` | Priority for `ksud` |
| `APP_NICE` | `-6` | Priority for the manager app |
| `APP_OOM` | `0` | Highest kill score allowed for the manager (lower = killed later) |
| `PKGS` | 3 managers | App package names to watch |


## Limits

- Keep in RAM is best-effort. On Android 10+, the system memory killer (`lmkd`) keeps its own copy of each app's kill score, so under heavy memory pressure it can still kill the manager. Some brands (MIUI/HyperOS, ColorOS, OneUI) also have their own app killers, which this module doesn't touch.
- Swiping the app away or using "Clear all" in recents still closes it, as intended.
- A hang must last a few seconds before it can be detected, so the module can't prevent the first freeze, only end it.
- If KernelSU itself is stalled, a stuck process can't exit until the kernel call returns, and the next root request may stall again.

## Uninstall

Remove the module in the manager and reboot. `uninstall.sh` removes the Doze and background exemptions; everything else is undone by the reboot.
