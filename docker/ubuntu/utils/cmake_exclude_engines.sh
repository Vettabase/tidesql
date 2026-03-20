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

case "${1:-}" in
    -h|--help)
        cat <<'EOF'
cmake_exclude_engines.sh - convert a comma-separated list of storage engine
names into cmake -DPLUGIN_xxx=NO flags.

Usage:
  cmake_exclude_engines.sh [DISABLED_ENGINES]
  cmake_exclude_engines.sh --help

Arguments:
  DISABLED_ENGINES  Comma-separated list of engine names to disable
                    (case-sensitive, must match cmake plugin names).
                    If omitted, the DISABLED_ENGINES environment variable
                    is used instead.

Output:
  A single line of cmake flags, e.g. -DPLUGIN_MROONGA=NO -DPLUGIN_ROCKSDB=NO
  If the list is empty, no output is produced (exit 0).

Example:
  # Disable Mroonga and RocksDB:
  FLAGS=$(cmake_exclude_engines.sh "MROONGA,ROCKSDB")
  cmake ... $FLAGS ...

  # Using the environment variable:
  DISABLED_ENGINES=MROONGA,ROCKSDB cmake_exclude_engines.sh
EOF
        exit 0
        ;;
esac

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
