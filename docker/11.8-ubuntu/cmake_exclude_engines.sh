#!/bin/sh
# cmake_exclude_engines.sh
#
# Converts a comma-separated DISABLED_ENGINES list into cmake -DPLUGIN_xxx=NO
# flags and prints them on a single line.
#
# Usage:
#   cmake_exclude_engines.sh [DISABLED_ENGINES]
#
# If no argument is supplied the DISABLED_ENGINES environment variable is used.
# When the list is empty the script produces no output (exit 0).

ENGINES="${1:-${DISABLED_ENGINES:-}}"

if [ -z "$ENGINES" ]; then
    exit 0
fi

FLAGS=""
IFS=','
for _eng in $ENGINES; do
    FLAGS="${FLAGS} -DPLUGIN_${_eng}=NO"
done
unset IFS

echo "${FLAGS# }"
