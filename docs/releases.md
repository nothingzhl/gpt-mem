# CI 与发布产物

版本号统一维护在根目录 `VERSION`，格式为 `major.minor.patch`。桌面 Info.plist、下载文件名和构建信息均从这里读取。

## 自动检查

PR、默认分支 `codex/report-history` 的推送，以及 Actions 页手动运行 CI，都会执行同一套流程：

1. macOS 15 的 Apple Silicon（arm64）和 Intel（x86_64）分别运行 Swift/XCTest 测试。
2. 构建 Release，执行 CLI 临时数据冒烟检查，以及来源编辑器、桌面 AI、会话、报告库和记忆库的模拟检查。
3. 打包后重新解压，检查版本、最低 macOS 版本、架构、可执行权限、签名和 CLI 启动，再上传 Actions Artifact（保留 14 天）。

下载 Actions 运行页面中对应架构的 Artifact，解压外层 GitHub Artifact 后，可见：

- `GPT-Manager-<版本>-macos-<架构>.zip`：含桌面 `.app` 和内置 CLI；使用 `ditto` 保留应用包结构及权限。
- `gpt-mem-<版本>-macos-<架构>.tar.gz`：独立 CLI、README 和第三方声明。
- `build-info-<版本>-macos-<架构>.json`：源提交、工作区是否有修改、Swift 工具链、架构及签名方式。
- `SHA256SUMS-<架构>.txt`：该架构三个文件的 SHA-256，可执行 `shasum -a 256 -c SHA256SUMS-arm64.txt`（Intel 替换架构名）。

两个架构分别下载，不是 Universal Binary。构建最低支持 macOS 14；CI 在 macOS 15 执行，不等于已在 macOS 14 真机验收。无图形登录的 CI 不运行窗口截图和交互性能测量，相关检查仍按 README 在本地执行。

测试任务使用只读仓库权限，不保存 checkout 凭据，不读取用户真实会话、AI 密钥或默认数据目录。CLI 冒烟包含短时只读进程采样，数据写入临时目录。Actions 固定到提交 SHA，由 Dependabot 每月提出升级 PR。

## 本地生成与验证

```sh
./scripts/build-artifacts.sh
./scripts/verify-artifacts.sh
```

已有当前源码的 Release 产物时使用 `./scripts/build-artifacts.sh --skip-build`。输出位于 `dist/artifacts`，同架构同版本会替换相应的生成文件。`--skip-build` 不核实二进制是否由当前提交编译，仅适用于刚完成构建的情况；CI 总是先构建再打包。脚本不启动或安装应用，不修改用户数据。

## 草稿 Release

先修改 `VERSION`，通过 PR 合并，并确认默认分支 CI 成功。维护者决定发布该版本时，在该提交创建并推送与 VERSION 一致的标签（例如 VERSION 为 0.19.4 时使用 `v0.19.4`）。标签不一致会失败。

版本标签触发双架构全量验证，通过后自动创建 **草稿 Release**，附上两个架构的全部文件及生成的版本说明。维护者审核内容后在 GitHub 点击发布。工作流不会自动公开发布；重新运行只允许更新草稿，遇到已发布 Release 会拒绝覆盖。删除草稿不会自动删除标签。

构建与测试任务没有写权限，仅组装草稿的任务拥有 `contents: write`。GitHub 自动提供的 `GITHUB_TOKEN` 足够，不需要 PAT、AI API Key 或 Apple 证书。私有仓库的下载仍受仓库访问权限控制。实际 Actions 执行取决于仓库 Actions 设置和可用运行额度。

当前使用 ad-hoc 签名，未配置 Developer ID 或 Apple 公证，下载后可能被 Gatekeeper 拦截。只有确认来源可信后才按 macOS 提示操作；不要全局关闭系统安全检查。面向外部用户正式分发前，应另行配置 Developer ID 签名和公证。
