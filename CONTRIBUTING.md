# 参与贡献

需要 macOS 14+、Swift 6；原生 XCTest 需要完整 Xcode。仅安装 Command Line Tools 时可运行同源测试。

从最新默认分支 `codex/report-history` 创建功能分支，经 PR 合并；不要直接推送默认分支。提交前检查 `git status`，只提交相关文件，运行 `git diff --check`。

```sh
./scripts/test.sh
swift build --configuration release
./scripts/smoke-cli.sh .build/release/gpt-mem
```

修改 AI 来源或认证还需运行 `python3 scripts/check-provider-editor.py` 和 `python3 scripts/check-desktop-ai.py`；其他模块执行 README 中对应的检查。CI 在两种架构运行原生 XCTest、Release 构建和桌面模拟检查。

测试使用临时目录与模拟模型，不提交真实 Key、会话日志、数据库或用户截图。截图必须来自可复现的模拟数据，并注明来源。安全问题按 [SECURITY.md](SECURITY.md) 私密报告。

PR 描述说明触发条件、行为变化、验证结果及未验证范围。修改存储格式应覆盖旧格式读取、冲突与失败保护。提交代表你有权以本仓库 Apache-2.0 许可证贡献相应改动；第三方代码必须保留原授权与声明。

发布版本与签名见 [发布说明](docs/releases.md) 和 [签名说明](docs/signing.md)。
