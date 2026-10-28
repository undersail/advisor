# 发布说明目录

每个发布版本的说明放在这里，**文件名必须等于 git tag 名**：

```
docs/releases/<tag>.md
```

例如 tag `v0.2.0` → `docs/releases/v0.2.0.md`。

若对应文件不存在，自动化流程会回退为根据提交历史自动生成变更日志。

## 自动发布（.github/workflows/release.yml）

推 `v*` 形态的 tag 会触发发布流水线：

1. `macos-15-intel`（Intel 池，`macos-latest` 现在是 macOS 26 arm64、容量紧张会领不到机器）
   上建 venv、装 py2app、跑 `release/build_standalone_app.sh`
   （版本号由 tag 传入，zip 名为 `Advisor-v<版本>-standalone.zip`）
2. 校验 zip 里必须有内嵌的 `claude-agent.pl` / `models.txt` / `providers.txt`
   与中文说明 —— 缺一件就红，避免发出在别人机器上跑不起来的包
3. 算 SHA256，存 artifact，再用 `gh release create` 建 Release
4. Release 正文取本目录的 `<tag>.md`；**缺失只警告并回退自动生成**，
   所以发版前请先提交这份文件，否则「版本说明」是机器拼的

发版前演练：Actions → Release → Run workflow（只构建、不发布）。
