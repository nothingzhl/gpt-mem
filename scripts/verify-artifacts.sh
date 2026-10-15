#!/usr/bin/env bash
set -euo pipefail
project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
architecture="${1:-$(uname -m)}"
case "$architecture" in arm64|x86_64) ;; *) echo "架构必须为 arm64 或 x86_64。" >&2; exit 1 ;; esac
version="$(cat "$project_dir/VERSION")"
output="$project_dir/dist/artifacts"
suffix="$version-macos-$architecture"
(
  cd "$output"
  /usr/bin/shasum -a 256 -c "SHA256SUMS-$architecture.txt"
)
python3 - "$output/build-info-$suffix.json" "$version" "$architecture" <<'PY'
import json
import re
import sys
with open(sys.argv[1]) as source:
    metadata = json.load(source)
assert metadata["version"] == sys.argv[2]
assert metadata["architecture"] == sys.argv[3]
assert metadata["minimumMacOS"] == "14.0"
assert re.fullmatch(r"[0-9a-f]{40}", metadata["commit"])
assert isinstance(metadata["dirty"], bool)
assert metadata["signing"] == "ad-hoc" and metadata["notarized"] is False
PY
stage="$(mktemp -d "${TMPDIR:-/tmp}/gpt-artifact-check.XXXXXX")"
trap 'rm -rf -- "$stage"' EXIT
/usr/bin/ditto -x -k "$output/GPT-Manager-$suffix.zip" "$stage"
mkdir "$stage/cli"
/usr/bin/tar -xzf "$output/gpt-mem-$suffix.tar.gz" -C "$stage/cli"
app="$stage/GPT Manager.app"
/usr/bin/plutil -lint "$app/Contents/Info.plist"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")" == "$version" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$app/Contents/Info.plist")" == "14.0" ]]
for binary in "$app/Contents/MacOS/gpt-manager" "$app/Contents/Resources/gpt-mem" "$stage/cli/gpt-mem"; do
  [[ -x "$binary" ]]
  [[ "$(/usr/bin/lipo -archs "$binary")" == "$architecture" ]]
  /usr/bin/codesign --verify --strict "$binary"
done
/usr/bin/codesign --verify --deep --strict "$app"
/usr/bin/cmp "$stage/cli/gpt-mem" "$app/Contents/Resources/gpt-mem"
GPT_MEM_HOME="$stage/history" "$stage/cli/gpt-mem" --help > "$stage/help.txt"
[[ ! -e "$stage/history" ]]
echo "产物解压、校验和、版本、架构、签名、可执行权限和 CLI 启动检查通过。"
