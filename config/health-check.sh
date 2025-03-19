#!/bin/sh
fileName="$FS_BASEDIR/.fs.lock"

# Check if lockfile exists
test -f $fileName || exit 1

# Check if content is correct
grep -Fxq "100" $fileName || exit 1

# Check if FirstSpirit is responding
curl -sL "http://localhost:8000" -o /dev/null || exit 1

# Explicit exit, for documentation purpose
exit 0