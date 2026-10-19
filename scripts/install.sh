#!/bin/sh
# Installs (or updates) MicKeeper.app in /Applications, keeping the background agent working across updates.
#
# Background Task Management pins the agent to the build it registered (its launch constraint, "LWCR"); with a
# signature that is not Developer ID that pin is the exact code hash. After the app is replaced, launchd can
# therefore refuse to start the new agent ("needs LWCR update", exit 78). What reliably refreshes the pin is a
# full pass of: unregister, wait until launchd has dropped the job, register, and start it once (kickstart).
# Right after copying a new build the first pass sometimes does not take, so it is repeated if needed.
set -e
BUILD="$1"
APP=/Applications/MicKeeper.app
CLI="$APP/Contents/MacOS/MicKeeper"
JOB="gui/$(id -u)/io.github.fratayaydn.mickeeper.agent"
UPDATER_JOB="gui/$(id -u)/io.github.fratayaydn.mickeeper.updater"

wait_until_dropped() {
    for job in "$UPDATER_JOB" "$JOB"; do
        for i in $(seq 1 70); do
            launchctl print "$job" >/dev/null 2>&1 || break
            sleep 0.5
        done
    done
}

agent_running() {
    launchctl print "$JOB" 2>/dev/null | grep -qE "^\s*state = running"
}

reregister() {
    "$CLI" --unregister
    wait_until_dropped
    sleep 1
    "$CLI" --register
    launchctl kickstart "$JOB" 2>/dev/null || true
    sleep 2
}

pkill -x MicKeeper || true
enabled=no
launchctl print "$JOB" >/dev/null 2>&1 && enabled=yes
if [ -x "$CLI" ]; then
    "$CLI" --unregister
    wait_until_dropped
fi

rm -rf "$APP"
cp -R "$BUILD" "$APP"

if [ "$enabled" = yes ]; then
    reregister
    agent_running || reregister
    agent_running || echo "MicKeeper: the background agent did not start; open MicKeeper and turn it off and on."
fi
open "$APP"
