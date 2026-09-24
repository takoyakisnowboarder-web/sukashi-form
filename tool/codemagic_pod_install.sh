#!/usr/bin/env bash
# Codemagic: write a Mac FLUTTER_ROOT then run pod install (no code signing).
# flutter sdk-path is not available on every stable channel.

set -u

podhelper_at() {
  [ -n "${1:-}" ] && [ -f "$1/packages/flutter_tools/bin/podhelper" ]
}

resolve_flutter_sdk() {
  local flutter_bin candidate from_doctor

  flutter_bin="$(command -v flutter || true)"
  if [ -n "$flutter_bin" ]; then
    if command -v realpath >/dev/null 2>&1; then
      flutter_bin="$(realpath "$flutter_bin")"
    elif [ -L "$flutter_bin" ]; then
      flutter_bin="$(readlink "$flutter_bin")"
    fi
    candidate="$(cd "$(dirname "$flutter_bin")/.." && pwd)"
    if podhelper_at "$candidate"; then
      printf '%s\n' "$candidate"
      return 0
    fi
  fi

  for candidate in \
    "${FLUTTER_ROOT:-}" \
    "$HOME/programs/flutter" \
    /Users/builder/programs/flutter \
    /opt/flutter
  do
    if podhelper_at "$candidate"; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  from_doctor="$(
    flutter doctor -v 2>/dev/null \
      | awk -F' at ' '/Flutter version/ { print $2; exit }'
  )"
  if podhelper_at "$from_doctor"; then
    printf '%s\n' "$from_doctor"
    return 0
  fi

  echo "Flutter SDK が見つからない。which flutter=$(command -v flutter || true)" >&2
  flutter doctor -v >&2 || true
  return 1
}

FLUTTER_SDK="$(resolve_flutter_sdk)"
APP_PATH="$PWD"
mkdir -p ios/Flutter
{
  echo "FLUTTER_ROOT=$FLUTTER_SDK"
  echo "FLUTTER_APPLICATION_PATH=$APP_PATH"
  echo "COCOAPODS_PARALLEL_CODE_SIGN=true"
  echo "FLUTTER_TARGET=lib/main.dart"
  echo "FLUTTER_BUILD_DIR=build"
  echo "PACKAGE_CONFIG=.dart_tool/package_config.json"
} > ios/Flutter/Generated.xcconfig
echo "FLUTTER_ROOT=$FLUTTER_SDK"

printf '%s\n' '--http1.1' '--retry' '5' '--retry-delay' '3' >> "$HOME/.curlrc"

attempt=1
while [ "$attempt" -le 5 ]; do
  if (cd ios && pod install --repo-update); then
    exit 0
  fi
  echo "pod install 失敗 ($attempt/5)。途中キャッシュを捨てて再試行します。"
  pod cache clean --all || true
  rm -rf ios/Pods
  attempt=$((attempt + 1))
  sleep $((attempt * 8))
done
exit 1
