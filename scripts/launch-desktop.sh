#!/usr/bin/env bash
set -euo pipefail
project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
app_path="$project_dir/dist/GPT Manager.app"
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  echo "用法：scripts/launch-desktop.sh [--data-dir 目录]"
  echo "仅打开本项目 dist/GPT Manager.app；其他参数交给桌面应用。"
  exit 0
fi
if [[ -L "$project_dir/dist" || -L "$app_path" ]]; then
  echo "项目应用路径为符号链接，拒绝打开项目之外的应用。" >&2
  exit 1
fi
if [[ ! -d "$app_path" || ! -x "$app_path/Contents/MacOS/gpt-manager" ]]; then
  echo "桌面应用尚未打包，请先运行 scripts/package-app.sh。" >&2
  exit 1
fi
bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app_path/Contents/Info.plist" 2>/dev/null || true)"
if [[ "$bundle_id" != "local.gpt-manager.desktop" ]]; then
  echo "目标不是本项目的 GPT Manager 应用，请重新打包。" >&2
  exit 1
fi
exec /usr/bin/open "$app_path" --args "$@"
