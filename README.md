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
- **Hang watchdog**: force-closes the manager (`am force-stop`) if its main thread is stuck in a kernel call for 2 checks in a row (15–30 s), or if Android shows "Application Not Responding" for it. `ksud` is never killed.

## Install

Download the zip from [Releases](../../releases) (or a build's Artifacts), then install it from the KernelSU manager's Module tab and reboot.

## Build

GitHub Actions builds the zip on every push. Push a tag such as `v1.1` to publish a release.

Local build:
```sh
zip -r ksu_stabilizer.zip module.prop service.sh customize.sh META-INF -x '*.DS_Store'
```

## Settings

Edit the values at the top of `service.sh`:

| Variable | Default | Meaning |
|---|---|---|
| `POLL` | `15` | Seconds between checks |
| `HANG_TICKS` | `2` | Stuck checks in a row before force-closing |
| `KSUD_NICE` | `-10` | Priority for `ksud` |
| `APP_NICE` | `-6` | Priority for the manager app |
| `PKGS` | 3 managers | App package names to watch |


## Limits

- A hang must last a few seconds before it can be detected, so the module can't prevent the first freeze, only end it.
- If KernelSU itself is stalled, a stuck process can't exit until the kernel call returns, and the next root request may stall again.

## Uninstall

Remove the module in the manager and reboot. All changes are undone on reboot.
