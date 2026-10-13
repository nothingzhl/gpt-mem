#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  echo "用法：scripts/install.sh [目标 bin 目录]"
  echo "默认安装到 ~/.local/bin；仅构建并复制当前用户的 CLI，不使用 sudo。"
  exit 0
fi
if [[ $# -gt 1 ]]; then
  echo "仅支持一个目标目录参数。" >&2
  exit 1
fi

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
destination_dir="${1:-${GPT_MEM_BIN_DIR:-$HOME/.local/bin}}"
swift build --package-path "$project_dir" --configuration release
binary_dir="$(swift build --package-path "$project_dir" --configuration release --show-bin-path)"
mkdir -p "$destination_dir"
/usr/bin/install -m 755 "$binary_dir/gpt-mem" "$destination_dir/gpt-mem"
echo "已安装：$destination_dir/gpt-mem"
case ":$PATH:" in
  *":$destination_dir:"*) ;;
  *) echo "目标目录尚未在 PATH 中；可直接运行上面的完整文件名，或自行配置 PATH。" ;;
esac
