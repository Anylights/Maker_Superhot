# Git 操作详细参考

## 分支管理

### 创建功能分支

```bash
git checkout -b feature/<name>
git push -u origin feature/<name>
```

### 合并分支

```bash
git checkout main
git merge feature/<name>
git push origin main
git branch -d feature/<name>          # 删除本地
git push origin --delete feature/<name>  # 删除远程
```

### 列出所有分支

```bash
git branch -a     # 本地+远程
git branch -vv    # 含跟踪信息
```

## 冲突解决

### push 被拒绝时

```bash
git pull --rebase origin <branch>
# 若有冲突：
#   1. 编辑冲突文件，解决 <<<< ==== >>>> 标记
#   2. git add <resolved-files>
#   3. git rebase --continue
# 若放弃 rebase：
#   git rebase --abort
git push origin <branch>
```

### 查看冲突文件

```bash
git diff --name-only --diff-filter=U
```

## 版本回滚

### 安全回滚（推荐）

生成一个新的 revert 提交，不改写历史：

```bash
git revert <commit-hash>
git push origin <branch>
```

### 回滚多个提交

```bash
git revert <oldest-commit>..<newest-commit>
git push origin <branch>
```

### 强制回滚（危险）

⚠️ 会丢失 commit 之后的所有提交，仅在确认无人依赖时使用：

```bash
git reset --hard <commit-hash>
git push --force origin <branch>
```

## Stash 暂存

### 临时保存工作区

```bash
git stash push -m "描述"
git stash list
git stash pop          # 恢复最近一次
git stash drop stash@{0}  # 删除指定
```

## Tag 标签

### 创建版本标签

```bash
git tag -a v1.0.0 -m "版本 1.0.0"
git push origin v1.0.0
```

### 列出标签

```bash
git tag -l "v*"
```

## 沙箱环境注意事项

1. **代理必须配置**：所有 git 网络操作前设置 `http.proxy http://127.0.0.1:1080`
2. **仅 HTTPS/SSH 出站**：不支持 git:// 协议
3. **git add 安全**：使用白名单方式仅添加用户目录，避免泄露引擎内部文件
4. **大文件注意**：PNG/音频等二进制文件会增大仓库体积，酌情使用 .gitignore

## .gitignore 推荐模板

```gitignore
# 引擎内部（绝不上传）
engine-docs/
examples/
templates/
urhox-libs/
schemas/
.emmylua/
lua-tools/
.claude/
.agent/
.tmp/
.build/
dist/
logs/

# 系统文件
.DS_Store
Thumbs.db
*.swp
*.swo
```
