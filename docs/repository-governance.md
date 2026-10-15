# 仓库维护规则

默认分支保持为 `codex/report-history`。仓库采用 Apache-2.0，第三方声明见根目录 THIRD-PARTY-NOTICES.md；公开源码不代表与 OpenAI、ChatGPT 或 Codex 官方有关联。

## 默认分支保护

配置保存在 `.github/branch-protection.json`，已通过 GitHub REST API 应用。要求 PR 合并、分支保持最新、GitHub Actions 的 arm64 和 x86_64 检查成功，以及全部讨论已解决；禁止强推和删除，管理员同样受限。

这是个人维护仓库，审批数量为 0，避免维护者无法批准自己 PR 的死锁；PR 和两项 CI 检查仍为强制要求。增加第二位维护者后，可把 required_approving_review_count 调整为 1。当前不要求已签名 Git 提交，也不改变默认分支名称。

更新配置后由具备管理权限的维护者执行：

```sh
gh api --method PUT repos/nothingzhl/gpt-mem/branches/codex%2Freport-history/protection \
  --input .github/branch-protection.json
gh api repos/nothingzhl/gpt-mem/branches/codex%2Freport-history/protection
```

状态检查绑定 GitHub Actions App（15368），不能用同名的普通 commit status 替代。源码、配置和工作流均经 PR 修改；Dependabot 更新也必须通过双架构 CI。Actions 使用只读权限，草稿发布任务单独获得内容写权限。

## 发布与安全

版本标签由维护者从已验证的默认分支提交创建，必须与 VERSION 一致。自动生成草稿后人工核对说明、两个架构的附件及校验和，再发布。详情见 releases.md。

启用 GitHub 私密漏洞报告，入口见 SECURITY.md。签名、公证尚待维护者配置 Apple secrets，接入及限制见 signing.md。
