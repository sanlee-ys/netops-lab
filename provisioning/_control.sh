#!/usr/bin/env bash
# Throwaway. Exists only to prove the CI lane can fail. Never merged.
set -euo pipefail

# SC2086 (unquoted expansion) and SC2046 (unquoted command substitution) —
# exactly the class of bug that would bite reprovision.sh on hardware.
target=$1
rm -rf $target
echo $(basename $target)
