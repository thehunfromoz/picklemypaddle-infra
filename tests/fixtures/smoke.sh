#!/bin/sh
# Stand-in smoke suite: passes when the page answers "version …", fails on
# purpose when the release is called SMOKEFAIL, and hangs (to be interrupted) for SLOW.
page="$(wget -qO- "$BASE_URL/")" || { echo "smoke: no answer from $BASE_URL"; exit 1; }
echo "smoke: got '$page' (EXPECT_STAGING=${EXPECT_STAGING:-unset})"
case "$page" in
  *SMOKEFAIL*) echo "smoke: failing on purpose"; exit 1 ;;
  *SLOW*)
    # A shell as PID 1 ignores SIGTERM unless it traps it; a real suite (node) stops on it.
    trap 'echo "smoke: stopped"; exit 143' TERM
    echo "smoke: taking a long time on purpose"
    sleep 300 &
    wait $!
    exit 0 ;;
  "version "*) exit 0 ;;
  *) exit 1 ;;
esac
