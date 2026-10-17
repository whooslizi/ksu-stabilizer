#!/system/bin/sh
# undo exempt_apps() from service.sh (these settings survive reboot)
for pkg in me.weishu.kernelsu com.rifsxd.ksunext com.sukisu.ultra; do
  dumpsys deviceidle whitelist -"$pkg" >/dev/null 2>&1
  cmd appops set "$pkg" RUN_ANY_IN_BACKGROUND default >/dev/null 2>&1
done
