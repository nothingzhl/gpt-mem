# Developer ID 签名与 Apple 公证

当前没有配置 Apple 证书或公证凭据，普通 CI 与版本标签产物继续使用 ad-hoc 签名；它不等于 Developer ID，也不能绕过 Gatekeeper。不要全局关闭 macOS 安全检查。

## 已接入的可选流程

`Signed macOS artifacts` 仅接受维护者从 Actions 手动触发，输入已存在、与 VERSION 一致的版本标签。两个架构仍运行全部测试；之后在临时钥匙串导入证书，以 Hardened Runtime 和可信时间戳签名，将应用包提交 Apple 公证并 staple 票据，再生成和验证产物。

缺少凭据或签名、公证失败时直接失败，不降级成 ad-hoc，也不覆盖已有本地产物。签名产物使用独立的 `signed-gpt-manager-macos-...` Artifact 名称，不自动替换草稿或已发布 Release 附件。清理步骤始终移除临时钥匙串及 P12/P8 文件。PR 工作流不接收任何 Apple secrets。

只有在拥有 Apple Developer Program 资格及 **Developer ID Application** 证书后，才配置以下仓库 Actions secrets。不要把证书、私钥或密码提交到代码、Issue 或聊天：

| Secret | 内容 |
| --- | --- |
| `APPLE_CERTIFICATE_P12_BASE64` | 带私钥的 Developer ID Application P12，base64 编码 |
| `APPLE_CERTIFICATE_PASSWORD` | P12 导出密码 |
| `APPLE_SIGN_IDENTITY` | 完整的 Developer ID Application 签名身份名称 |
| `APPLE_NOTARY_KEY_BASE64` | App Store Connect 公证 API 私钥 P8，base64 编码 |
| `APPLE_NOTARY_KEY_ID` | 对应 API Key ID |
| `APPLE_NOTARY_ISSUER_ID` | 对应团队 Issuer ID |

配置完后，选择默认分支上的 `Signed macOS artifacts`，输入已发布版本或草稿版本的标签运行。测试成功后下载对应架构的 signed Artifact。正式替换发布附件前，维护者应核对源提交、签名 Authority、公证票据以及干净 macOS 上的启动行为。构建信息会记录 `developer-id` 和公证结果。独立 CLI 带 Developer ID 签名；可离线验证的 staple 票据位于 `.app`，不声称原始 CLI 文件有独立票据。

## 本机使用

如果本机已安装 Developer ID 证书，并使用 `xcrun notarytool store-credentials` 创建自己的钥匙串公证 profile，可运行：

```sh
GPT_MANAGER_SIGN_IDENTITY='Developer ID Application: Your Name (TEAMID)' \
GPT_MANAGER_NOTARY_PROFILE='your-notary-profile' \
./scripts/build-artifacts.sh
./scripts/verify-artifacts.sh
```

使用独立钥匙串时额外设置 `GPT_MANAGER_SIGNING_KEYCHAIN`。没有签名环境变量时始终为 ad-hoc。`scripts/prepare-signing.sh` 专用于 GitHub 临时 runner，不在个人登录钥匙串导入证书。

当前已验证无凭据时的失败保护、默认 ad-hoc 打包和签名工作流静态检查。没有真实证书，尚未向 Apple 提交公证或验证 Developer ID 产物；配置 secrets 后必须实跑并人工验收。

参考：[Apple Developer ID](https://developer.apple.com/developer-id/)、[Apple 公证流程](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)。
