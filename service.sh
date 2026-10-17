#!/system/bin/sh

MODDIR=${0%/*}
LOG=/data/adb/ksu_stabilizer.log
LOG_MAX=65536 
POLL=15  # seconds between checks; lower = faster reaction, more wakeups
KSUD_NICE=-10 
APP_NICE=-6  
HANG_TICKS=2  # main thread stuck in D for 2 polls (15-30s) = hung
APP_OOM=0  # oom_score_adj cap for the manager (0 = same as the app on screen)
PKGS="me.weishu.kernelsu com.rifsxd.ksunext com.sukisu.ultra"

log() { echo "$(date '+%m-%d %H:%M:%S') $*" >> "$LOG" 2>/dev/null; }

has() { command -v "$1" >/dev/null 2>&1; }

rotate_log() {
  [ -f "$LOG" ] || return 0
  sz=$(wc -c < "$LOG" 2>/dev/null)
  [ "${sz:-0}" -gt "$LOG_MAX" ] && mv -f "$LOG" "$LOG.old" 2>/dev/null
  return 0
}

wait_boot() {
  i=0
  until [ "$(getprop sys.boot_completed)" = "1" ]; do
    sleep 2; i=$((i + 2))
    if [ "$i" -ge 300 ]; then log "boot: sys.boot_completed timeout, continuing"; break; fi
  done
  sleep 10
}

raise_sysctl() {
  key=$1; val=$2
  p=/proc/sys/$(echo "$key" | tr . /)
  if [ ! -w "$p" ]; then log "sysctl: $key absent/ro, skip"; return 0; fi
  cur=$(cat "$p" 2>/dev/null)
  if [ "${cur:-0}" -ge "$val" ] 2>/dev/null; then
    log "sysctl: $key=$cur (>= $val, keep)"; return 0
  fi
  if echo "$val" > "$p" 2>/dev/null; then
    log "sysctl: $key $cur -> $val"
  else
    log "sysctl: $key write failed"
  fi
}

tune_buffers() {
  raise_sysctl net.core.rmem_max 8388608
  raise_sysctl net.core.wmem_max 8388608
  raise_sysctl net.core.rmem_default 524288
  raise_sysctl net.core.wmem_default 524288
  raise_sysctl net.unix.max_dgram_qlen 512
  raise_sysctl net.core.netdev_max_backlog 2048
}

net_rules() {
  if ! has ip; then log "net: ip binary missing, skip"; return 0; fi

  if ip rule show 2>/dev/null | grep -q 'to 127.0.0.0/8 lookup local'; then
    log "net: v4 loopback rule present"
  elif ip rule add to 127.0.0.0/8 lookup local pref 10 2>/dev/null; then
    log "net: v4 loopback rule added (pref 10)"
  else
    log "net: v4 loopback rule add failed"
  fi

  if [ -d /proc/sys/net/ipv6 ]; then
    if ip -6 rule show 2>/dev/null | grep -q 'to ::1 lookup local'; then
      log "net: v6 loopback rule present"
    elif ip -6 rule add to ::1/128 lookup local pref 10 2>/dev/null; then
      log "net: v6 loopback rule added (pref 10)"
    else
      log "net: v6 loopback rule add failed"
    fi
  fi
}

CPUSET=""
CPUCTL=""
pick_cgroups() {
  for d in /dev/cpuset/top-app /dev/cpuset/foreground; do
    if [ -w "$d/cgroup.procs" ] || [ -w "$d/tasks" ]; then CPUSET=$d; break; fi
  done
  for d in /dev/cpuctl/top-app /dev/stune/top-app; do
    if [ -w "$d/cgroup.procs" ] || [ -w "$d/tasks" ]; then CPUCTL=$d; break; fi
  done
  log "cgroup: cpuset=${CPUSET:-none} cpuctl=${CPUCTL:-none}"
}

cg_move() {
  dir=$1; pid=$2
  [ -n "$dir" ] || return 1
  if [ -w "$dir/cgroup.procs" ]; then
    echo "$pid" > "$dir/cgroup.procs" 2>/dev/null && return 0
  fi
  # fallback: per-thread
  ok=1
  for t in /proc/"$pid"/task/*; do
    echo "${t##*/}" > "$dir/tasks" 2>/dev/null && ok=0
  done
  return $ok
}

set_nice() {
  pid=$1; target=$2; n=0
  has renice || return 1
  for t in /proc/"$pid"/task/*; do
    tid=${t##*/}
    cur=$(sed 's/.*) //' "$t/stat" 2>/dev/null | cut -d' ' -f17)
    [ -n "$cur" ] || continue
    d=$((target - cur))
    [ "$d" -eq 0 ] && continue
    renice -n "$d" -p "$tid" >/dev/null 2>&1 && n=$((n + 1))
  done
  echo "$n"
}

boost() {
  pid=$1; nice=$2; tag=$3; pin=$4
  [ -d "/proc/$pid" ] || return 0
  r=$(set_nice "$pid" "$nice") || r="renice-missing"
  c="-"
  if [ "$pin" = "1" ]; then
    cg_move "$CPUSET" "$pid" && c="cpuset" || c="cpuset-fail"
    cg_move "$CPUCTL" "$pid" && c="$c+cpuctl"
  fi
  log "boost: $tag pid=$pid nice->$nice threads=$r cg=$c"
}

nice_of() { sed 's/.*) //' "/proc/$1/stat" 2>/dev/null | cut -d' ' -f17; }

# new PID, or Android reset its priority (happens on every open/foreground switch)
need_boost() {
  case " $seen " in *" $1 "*) [ "$(nice_of "$1")" != "$2" ] ;; *) return 0 ;; esac
}

# main thread stuck in kernel (D state) for HANG_TICKS polls, or ANR dialog up -> force-stop
# shortcut: hang_<pid> vars of dead PIDs are never unset, tiny leak; fine unless PIDs churn for weeks
check_hang() {
  pkg=$1; pid=$2
  st=$(sed 's/.*) //' "/proc/$pid/stat" 2>/dev/null | cut -d' ' -f1)
  eval c=\${hang_$pid:-0}
  if [ "$st" = "D" ]; then c=$((c + 1)); else c=0; fi
  eval hang_$pid=$c
  anr=0
  dumpsys window 2>/dev/null | grep -q "Application Not Responding: $pkg" && anr=1
  if [ "$c" -ge "$HANG_TICKS" ] || [ "$anr" = 1 ]; then
    log "hang: $pkg pid=$pid state=$st dticks=$c anr=$anr -> force-stop"
    am force-stop "$pkg" 2>/dev/null || kill -9 "$pid" 2>/dev/null
    eval unset hang_$pid
  fi
}

# keep the manager in RAM: battery/background exemptions, once at boot (reverted by uninstall.sh)
exempt_apps() {
  for pkg in $PKGS; do
    pm path "$pkg" >/dev/null 2>&1 || continue
    dumpsys deviceidle whitelist +"$pkg" >/dev/null 2>&1
    cmd appops set "$pkg" RUN_ANY_IN_BACKGROUND allow >/dev/null 2>&1
    am set-standby-bucket "$pkg" active >/dev/null 2>&1
    log "keep: $pkg exempted from doze/background limits"
  done
}

# Android raises oom_score_adj when the app goes to background; pull it back down every poll
keep_alive() {
  p=/proc/$1/oom_score_adj
  cur=$(cat "$p" 2>/dev/null)
  if [ "${cur:-0}" -gt "$APP_OOM" ] 2>/dev/null; then echo "$APP_OOM" > "$p" 2>/dev/null; fi
}

# ---------- watcher ----------
watch_loop() {
  seen=""
  while :; do
    if [ -f "$MODDIR/disable" ] || [ -f "$MODDIR/remove" ]; then
      log "watch: module disabled/removed, exit"; exit 0
    fi
    now=""
    for pid in $(pidof ksud 2>/dev/null); do
      now="$now $pid"
      need_boost "$pid" "$KSUD_NICE" && boost "$pid" "$KSUD_NICE" ksud 1
    done

    for pkg in $PKGS; do
      for pid in $(pidof "$pkg" 2>/dev/null); do
        now="$now $pid"
        need_boost "$pid" "$APP_NICE" && boost "$pid" "$APP_NICE" "$pkg" 0
        keep_alive "$pid"
        check_hang "$pkg" "$pid"
      done
    done
    seen=$now
    sleep "$POLL"
  done
}

main() {
  [ -x /data/adb/ksud ] || exit 0  # KernelSU only
  rotate_log
  log "=== start: kernel $(uname -r), sdk $(getprop ro.build.version.sdk) ==="
  wait_boot
  tune_buffers
  net_rules
  pick_cgroups
  exempt_apps
  watch_loop
}

(main) </dev/null >/dev/null 2>&1 &
exit 0
