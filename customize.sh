# KernelSU / Magisk installer hook (files auto-extracted to $MODPATH)
[ "$KSU" = "true" ] || abort "! KernelSU only"
ui_print "- KSU Stabilizer"
ui_print "- Log: /data/adb/ksu_stabilizer.log"
set_perm_recursive "$MODPATH" 0 0 0755 0644
set_perm "$MODPATH/service.sh" 0 0 0755
