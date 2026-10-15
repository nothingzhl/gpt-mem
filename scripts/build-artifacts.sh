#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
if [[ $# -gt 1 || ( $# -eq 1 && "$1" != "--skip-build" ) ]]; then
  echo "用法：scripts/build-artifacts.sh [--skip-build]" >&2; exit 1
fi
version="$(cat "$project_dir/VERSION")"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "VERSION 必须为 major.minor.patch 格式。" >&2; exit 1
fi
"$project_dir/scripts/package-app.sh" "$@"
app="$project_dir/dist/GPT Manager.app"
cli="$app/Contents/Resources/gpt-mem"
architecture="$(/usr/bin/lipo -archs "$app/Contents/MacOS/gpt-manager")"
case "$architecture" in arm64|x86_64) ;; *) echo "仅支持单架构 arm64 或 x86_64 产物。" >&2; exit 1 ;; esac
if [[ "$(/usr/bin/lipo -archs "$cli")" != "$architecture" ]]; then
  echo "桌面与 CLI 架构不一致。" >&2; exit 1
fi
output="$project_dir/dist/artifacts"
if [[ -L "$output" || ( -e "$output" && ! -d "$output" ) ]]; then
  echo "产物目录必须是普通目录。" >&2; exit 1
fi
mkdir -p "$output"
stage="$(mktemp -d "$project_dir/dist/.artifacts.XXXXXX")"
trap 'rm -rf -- "$stage"' EXIT
suffix="$version-macos-$architecture"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app" "$stage/GPT-Manager-$suffix.zip"
mkdir "$stage/cli"
/usr/bin/install -m 755 "$cli" "$stage/cli/gpt-mem"
/usr/bin/install -m 644 "$project_dir/README.md" "$stage/cli/README.md"
for notice in LICENSE NOTICE THIRD-PARTY-NOTICES.md; do
  /usr/bin/install -m 644 "$project_dir/$notice" "$stage/cli/$notice"
done
COPYFILE_DISABLE=1 /usr/bin/tar -czf "$stage/gpt-mem-$suffix.tar.gz" -C "$stage/cli" gpt-mem README.md LICENSE NOTICE THIRD-PARTY-NOTICES.md
python3 - "$project_dir" "$version" "$architecture" "$stage/build-info-$suffix.json" <<'PY'
import json
import pathlib
import os
import subprocess
import sys
root, version, architecture, destination = sys.argv[1:]
def command(*args):
    return subprocess.check_output(args, cwd=root, text=True).strip()
metadata = {
    "version": version, "architecture": architecture, "minimumMacOS": "14.0",
    "commit": command("git", "rev-parse", "HEAD"),
    "dirty": bool(command("git", "status", "--porcelain", "--untracked-files=normal")),
    "swift": command("swift", "--version"),
    "signing": "ad-hoc" if os.environ.get("GPT_MANAGER_SIGN_IDENTITY", "-") == "-" else "developer-id",
    "notarized": bool(os.environ.get("GPT_MANAGER_NOTARY_PROFILE")),
}
pathlib.Path(destination).write_text(json.dumps(metadata, indent=2) + "\n")
PY
(
  cd "$stage"
  /usr/bin/shasum -a 256 "GPT-Manager-$suffix.zip" "gpt-mem-$suffix.tar.gz" "build-info-$suffix.json" > "SHA256SUMS-$architecture.txt"
)
# Only replace the explicitly named generated files; retain other architectures.
for file in "$stage"/*.zip "$stage"/*.tar.gz "$stage"/*.json "$stage"/SHA256SUMS-*.txt; do
  target="$output/$(basename "$file")"
  if [[ -L "$target" || ( -e "$target" && ! -f "$target" ) ]]; then
    echo "拒绝覆盖非普通产物：$target" >&2; exit 1
  fi
done
for file in "$stage"/*.zip "$stage"/*.tar.gz "$stage"/*.json "$stage"/SHA256SUMS-*.txt; do
  mv -f "$file" "$output/"
done
echo "发布产物：${output}（${architecture}，${version}）"
