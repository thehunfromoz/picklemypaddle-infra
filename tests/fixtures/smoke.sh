#!/bin/sh
# Stand-in smoke suite: passes when the page answers "version …", fails on
# purpose when the release is called SMOKEFAIL.
page="$(wget -qO- "$BASE_URL/")" || { echo "smoke: no answer from $BASE_URL"; exit 1; }
echo "smoke: got '$page'"
case "$page" in
  *SMOKEFAIL*) echo "smoke: failing on purpose"; exit 1 ;;
  "version "*) exit 0 ;;
  *) exit 1 ;;
esac
