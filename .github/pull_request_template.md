## Summary / 概述

<!-- What does this PR do? Link the related issue if any. / 这个 PR 做了什么？关联 issue 请链接。 -->

Closes #

## Type / 类型

- [ ] Bug fix / 修复
- [ ] New feature / 新功能
- [ ] Refactor / 重构
- [ ] Docs / 文档
- [ ] Tests / 测试
- [ ] Chore / 工程化

## Checklist / 检查清单

- [ ] `xcodebuild build -scheme Voxmit -destination 'platform=macOS'` passes
- [ ] `xcodebuild test -scheme Voxmit -destination 'platform=macOS'` passes; new logic has tests / 新逻辑已补测试
- [ ] System-permission features tested via protocol mocks, no real permissions required / 系统权限功能走协议 mock，不依赖真实权限
- [ ] User-facing docs updated in pairs (README ↔ README.zh-CN, docs/index ↔ index.zh-CN) / 用户可见变更已双语同步文档
- [ ] `docs/USER_GUIDE.md` updated if user-visible behavior changed / 用户可见行为变更已同步 USER_GUIDE
- [ ] Task progress recorded in `PLAN.md`; pitfalls in `docs/implementation-notes.md` / 进度记入 PLAN.md，踩坑记入 implementation-notes
