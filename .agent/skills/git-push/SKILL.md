---
name: git-push
description: |
  Git 版本控制与 GitHub 同步管理。在以下场景触发：
  (1) 会话开始/项目初始化时（首次配置仓库信息）,
  (2) 用户说「push」「上传」「推送」「提交到GitHub」「同步GitHub」「备份代码」「上传代码」或其他同义表达,
  (3) 用户要求创建分支、切换分支、回滚版本、查看提交历史,
  (4) 用户设置了 auto_push 后每次对话工作结束时自动推送,
  (5) 用户提到 git/GitHub/版本控制相关操作。
---

# Git Push — GitHub 版本控制 Skill

## 首次配置流程

当 `.agent/git-config.json` 不存在时，依次询问用户：

1. **GitHub 仓库链接** — 例：`https://github.com/user/repo`
2. **认证方式** — HTTPS Token 或 SSH
3. **是否每次对话工作结束后自动 push** — yes/no

将配置写入 `.agent/git-config.json`：

```json
{
  "repo_url": "https://github.com/user/repo",
  "auth_type": "token",
  "token": "ghp_xxx",
  "branch": "main",
  "auto_push": true,
  "user_name": "user",
  "user_email": "user@users.noreply.github.com",
  "exclude_dirs": ["engine-docs", "examples", "templates", "urhox-libs", "schemas", ".emmylua", "lua-tools", ".claude", ".tmp", "dist", "logs", ".build", "node_modules"]
}
```

配置完成后立即执行一次连通性测试（`git ls-remote`）。

## 核心操作

### Push（推送）

触发词：push、上传、推送、提交、同步、备份

```
1. 读取 .agent/git-config.json
2. 配置 git user.name / user.email
3. 配置 remote URL（含 token 或 SSH）
4. 配置代理：git config http.proxy http://127.0.0.1:1080
5. git add — 仅添加用户目录（scripts/ assets/ docs/ 等），排除 exclude_dirs
6. git status 检查是否有变更，无变更则提示并跳过
7. 生成有意义的中文 commit message（基于 diff 内容摘要）
8. git commit && git push
9. 报告：提交哈希、变更文件数、推送状态
```

### 创建分支

触发词：创建分支、新建分支、new branch

```
1. git checkout -b <branch-name>
2. git push -u origin <branch-name>
3. 更新 git-config.json 的 branch 字段
```

### 切换分支

触发词：切换分支、switch branch、checkout

```
1. git fetch origin
2. git checkout <branch-name>
3. 更新 git-config.json 的 branch 字段
```

### 回滚版本

触发词：回滚、撤销、rollback、revert

```
1. git log --oneline -10 展示最近 10 条提交
2. 让用户选择回滚目标
3. 两种策略（让用户选）：
   a. git revert <commit> —— 安全回滚，生成新提交
   b. git reset --hard <commit> && git push --force —— 强制回滚（警告数据丢失风险）
```

### 查看历史

触发词：历史、日志、log、提交记录

```
git log --oneline -20 --graph --decorate
```

### 查看状态

触发词：状态、status、diff、变更

```
git status --short && git diff --stat
```

## Auto Push 机制

当 `auto_push: true` 时：
- 每次对话中完成代码修改/构建后，在回复末尾自动执行 push 流程
- push 前先 `git status` 确认有变更
- 无变更时静默跳过，不打扰用户

## 关键规则

1. **绝不推送敏感目录** — exclude_dirs 中的目录永远不 `git add`
2. **代理必须配置** — 沙箱环境需设置 `http.proxy http://127.0.0.1:1080`
3. **commit message 用中文** — 简明描述本次变更内容，使用 conventional commits 格式（feat/fix/refactor/docs）
4. **push 失败时** — 报告错误信息，建议 `git pull --rebase` 解决冲突
5. **token 安全** — 配置文件仅存于 .agent/，该目录已在 .gitignore 中

## 配置文件位置

- 配置：`.agent/git-config.json`
- 详细操作参考：`references/git-operations.md`（分支管理、冲突解决等高级场景）
