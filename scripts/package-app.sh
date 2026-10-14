#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "用法：scripts/package-app.sh [--skip-build] [--bin gpt-manager路径] [--cli-bin gpt-mem路径]"
  echo "构建并打包到本项目 dist/GPT Manager.app，不启动或安装应用。"
  echo "--skip-build 复用 release 产物；--bin 指定桌面产物并跳过构建，默认复用同目录 CLI。"
}

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
skip_build=false
binary_path="${GPT_MANAGER_BIN:-}"
cli_binary_path="${GPT_MANAGER_CLI_BIN:-}"
if [[ -n "$binary_path" ]]; then skip_build=true; fi
while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-build) skip_build=true; shift ;;
    --bin)
      if [[ $# -lt 2 || -z "$2" ]]; then echo "--bin 需要现有可执行产物路径。" >&2; exit 1; fi
      binary_path="$2"; skip_build=true; shift 2 ;;
    --cli-bin)
      if [[ $# -lt 2 || -z "$2" ]]; then echo "--cli-bin 需要现有 CLI 产物路径。" >&2; exit 1; fi
      cli_binary_path="$2"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) echo "不支持的参数：$1" >&2; usage >&2; exit 1 ;;
  esac
done

if [[ "$skip_build" == false ]]; then
  swift build --package-path "$project_dir" --configuration release --product gpt-manager
  swift build --package-path "$project_dir" --configuration release --product gpt-mem
fi
if [[ -z "$binary_path" ]]; then
  binary_dir="$(swift build --package-path "$project_dir" --configuration release --show-bin-path)"
  binary_path="$binary_dir/gpt-manager"
fi
cli_binary_path="${cli_binary_path:-$(dirname "$binary_path")/gpt-mem}"
validate_binary() {
  local source="$1" name="$2" option="$3" binary_type
  if [[ ! -f "$source" || ! -x "$source" ]]; then
    echo "找不到可执行的 $name 产物；请先构建或通过 $option 指定。" >&2
    return 1
  fi
  binary_type="$(/usr/bin/file -b "$source")"
  case "$binary_type" in
    *Mach-O*) ;;
    *) echo "$name 必须是 macOS 原生 Mach-O 可执行文件。" >&2; return 1 ;;
  esac
}
validate_binary "$binary_path" "gpt-manager" "--bin"
validate_binary "$cli_binary_path" "gpt-mem（报告导出必需）" "--cli-bin"

dist_dir="$project_dir/dist"
app_path="$dist_dir/GPT Manager.app"
if [[ -L "$dist_dir" || -L "$app_path" ]]; then
  echo "dist 或目标应用为符号链接，拒绝覆盖项目之外的路径。" >&2
  exit 1
fi
if [[ -e "$dist_dir" && ! -d "$dist_dir" ]]; then
  echo "dist 已存在且不是目录，拒绝覆盖。" >&2; exit 1
fi
if [[ -e "$app_path" ]]; then
  existing_id=""
  if [[ -f "$app_path/Contents/Info.plist" ]]; then
    existing_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app_path/Contents/Info.plist" 2>/dev/null || true)"
  fi
  if [[ ! -f "$app_path/Contents/Resources/.gpt-manager-package" && "$existing_id" != "local.gpt-manager.desktop" ]]; then
    echo "目标已存在且不是本项目的 GPT Manager 产物，拒绝覆盖。" >&2; exit 1
  fi
fi

mkdir -p "$dist_dir"
stage_dir="$(mktemp -d "$dist_dir/.gpt-manager-package.XXXXXX")"
trap 'rm -rf -- "$stage_dir"' EXIT
stage_app="$stage_dir/GPT Manager.app"
mkdir -p "$stage_app/Contents/MacOS" "$stage_app/Contents/Resources"
/usr/bin/install -m 755 "$binary_path" "$stage_app/Contents/MacOS/gpt-manager"
/usr/bin/install -m 755 "$cli_binary_path" "$stage_app/Contents/Resources/gpt-mem"
cat > "$stage_app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>local.gpt-manager.desktop</string>
  <key>CFBundleName</key><string>GPT Manager</string>
  <key>CFBundleDisplayName</key><string>GPT Manager</string>
  <key>CFBundleExecutable</key><string>gpt-manager</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleShortVersionString</key><string>0.16.0</string>
  <key>CFBundleVersion</key><string>0.16.0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST
if [[ -f "$project_dir/THIRD-PARTY-NOTICES.md" ]]; then
  /usr/bin/install -m 644 "$project_dir/THIRD-PARTY-NOTICES.md" "$stage_app/Contents/Resources/THIRD-PARTY-NOTICES.md"
fi
echo "local.gpt-manager.desktop" > "$stage_app/Contents/Resources/.gpt-manager-package"
/usr/bin/plutil -lint "$stage_app/Contents/Info.plist"
# Ad-hoc signing is local only and requires no developer account or certificate.
/usr/bin/codesign --force --sign - "$stage_app/Contents/Resources/gpt-mem"
/usr/bin/codesign --verify --strict "$stage_app/Contents/Resources/gpt-mem"
/usr/bin/codesign --force --sign - "$stage_app"
/usr/bin/codesign --verify --strict "$stage_app"

# Replace only a validated project artifact, after the new bundle passes checks.
if [[ -e "$app_path" ]]; then rm -rf -- "$app_path"; fi
mv "$stage_app" "$app_path"
echo "已打包：$app_path"
echo "可运行 scripts/launch-desktop.sh 或手动打开该应用。"
