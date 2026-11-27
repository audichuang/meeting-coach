#!/bin/bash
# The only way to use the MC simulator. It restores the resident device from the NAS,
# boots it before xcodebuild (an xcodebuild-booted simulator is shut down 30 s later and
# PosterBoard data rots), holds a sim-vault lease so nobody parks or shuts it down
# mid-run, and parks it back to the NAS once it has been idle for MC_SIM_IDLE_PARK seconds.
#
#   scripts/sim.sh xcodebuild test [-only-testing:KurnTests/Suite]   # or build, etc.
#   scripts/sim.sh up      # manual check: lease + boot, prints the UDID
#   scripts/sim.sh down    # end the manual check (idle park follows)
#   scripts/sim.sh park    # park now
#
# sim-vault exit codes are passed on; see `sim-vault --help`. Never create another
# "MC iPad mini" when ensure/run fails: an empty twin would overwrite the archive on park.
set -euo pipefail

name="${MC_SIM_NAME:-MC iPad mini}"
root="$(cd "$(dirname "$0")/.." && pwd)"
# One build cache shared by every worktree and round; runs are serialized by the lease.
derived="$HOME/Library/Caches/meeting-coach/DerivedData"
state="$HOME/Library/Caches/meeting-coach/sim-idle"
idle="${MC_SIM_IDLE_PARK:-900}"

# shortcut: a detached sleeper, not a launchd job; if the machine sleeps or the process is
# killed the device stays local until the next run schedules another park.
schedule_park() {
  mkdir -p "$(dirname "$state")"
  local token="$$.$RANDOM"
  echo "$token" >"$state"
  # Only the newest schedule parks; park itself refuses (8) while anyone holds a lease.
  nohup /bin/bash -c '
    sleep "$1"
    [ "$(cat "$2" 2>/dev/null)" = "$3" ] || exit 0
    sim-vault park "$4" --shutdown --missing-ok
  ' _ "$idle" "$state" "$token" "$name" >>"$state.log" 2>&1 </dev/null &
  disown
  echo "閒置 ${idle}s 後自動收回 NAS（log: $state.log）" >&2
}

case "${1:-}" in
  xcodebuild)
    shift
    # Keep the last 3 days of test results; xcodebuild adds one .xcresult per run.
    find "$derived/Logs/Test" -maxdepth 1 -name '*.xcresult' -mtime +3 -exec rm -rf {} + 2>/dev/null || true
    result="$(mktemp -t mc-sim-run)"
    # Schedule the idle park even when the run is interrupted.
    trap 'rm -f "$result"; schedule_park' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM HUP
    waited=0
    while :; do
      rc=0
      heavy -- sim-vault run "$name" --lease mc:run --boot --deny-other-leases --result-file "$result" -- \
        /bin/bash -c 'cd "$1/app" && shift && exec xcodebuild -project Kurn.xcodeproj -scheme Kurn \
          -destination "platform=iOS Simulator,id=$SIM_VAULT_UDID" -derivedDataPath "$0" "$@"' \
        "$derived" "$root" "$@" || rc=$?
      # Another session holds the device: wait instead of making a second simulator.
      if [[ $rc == 8 ]] && grep -q '"stage": *"acquire"' "$result" && ((waited < 1800)); then
        echo "${name} 正被別人使用，30 秒後重試（已等 ${waited}s）" >&2
        sleep 30; waited=$((waited + 30)); continue
      fi
      break
    done
    exit "$rc"
    ;;
  up)
    sim-vault ensure "$name" --boot --lease auto --lease-scope "$root" --lease-prefix mc:up --wait 1800
    ;;
  down)
    rc=0
    sim-vault release "$name" --lease auto --lease-scope "$root" || rc=$?
    schedule_park
    exit "$rc"
    ;;
  park)
    echo cancelled >"$state" 2>/dev/null || true
    exec sim-vault park "$name" --shutdown --missing-ok
    ;;
  *)
    sed -n '7,10p' "$0" >&2
    exit 2
    ;;
esac
