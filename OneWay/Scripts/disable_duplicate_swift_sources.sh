#!/bin/sh
set -eu

# Xcode 16 filesystem-synchronized groups compile any Swift file that appears
# under the synchronized app folder. iCloud Drive can create conflict copies
# such as "APIConfig 2.swift" on a Mac, which then define duplicate types and
# break the build even though those files are not tracked by git.
app_dir="${SRCROOT:-$(pwd)}/OneWay/App"

if [ ! -d "$app_dir" ]; then
  exit 0
fi

find "$app_dir" -maxdepth 1 -type f \( \
  -name '* 2.swift' -o \
  -name '* copy.swift' -o \
  -name '* Copy.swift' \
\) -print | while IFS= read -r duplicate; do
  disabled="${duplicate}.disabled"
  echo "Disabling duplicate Swift source before compile: ${duplicate} -> ${disabled}"
  mv -f "$duplicate" "$disabled"
done
