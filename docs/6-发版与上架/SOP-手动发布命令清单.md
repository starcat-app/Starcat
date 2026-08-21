# SOP-手动发布命令清单

> 创建：2026-07-09
> 用途：只保留手动发布常用命令。App Store 与 Direct 两条渠道分开执行。

## App Store 渠道

```bash
# 进入 Starcat 主仓库。
cd /Users/dong4j/Developer/1.AI/ai-incubator/Starcat

# 打包 App Store archive。
STARCAT_DEVELOPMENT_TEAM=8WCUMGCWMB ./scripts/package-appstore.sh

# 只在本机导出最终 App Store pkg，不上传 App Store Connect。
STARCAT_DEVELOPMENT_TEAM=8WCUMGCWMB \
STARCAT_APPSTORE_EXPORT=1 \
STARCAT_APPSTORE_ALLOW_PROVISIONING_UPDATES=1 \
STARCAT_APPSTORE_SKIP_OPEN=1 \
./scripts/package-appstore.sh

# 检查最终 Installer 签名；应为 Mac Installer Distribution。
pkgutil --check-signature dist/appstore/export/Starcat.pkg

# Make 快捷入口：打包 App Store archive。
make package-appstore

# Make 快捷入口：打开 archive，交给 Xcode Organizer 上传。
make open-appstore-archive

# 指向 archive 中的 App Store app。
APP="/Users/dong4j/Developer/1.AI/ai-incubator/Starcat/dist/appstore/Starcat-AppStore.xcarchive/Products/Applications/Starcat.app"

# 检查 App Store 包版本号。
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist"

# 检查 App Store Bundle ID。
/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist"

# 检查运行时分发渠道。
/usr/libexec/PlistBuddy -c 'Print :STARCAT_DISTRIBUTION' "$APP/Contents/Info.plist"

# 检查 App Store 包 entitlements。
codesign -d --entitlements /tmp/starcat-appstore-entitlements.plist "$APP" && cat /tmp/starcat-appstore-entitlements.plist

# 本地打开 archive 中的 App Store app 做冒烟验证。
open "$APP"

# 打开 Xcode Organizer 上传 App Store Connect。
open /Users/dong4j/Developer/1.AI/ai-incubator/Starcat/dist/appstore/Starcat-AppStore.xcarchive

# 查看 App Store archive 构建日志。
tail -120 /Users/dong4j/Developer/1.AI/ai-incubator/Starcat/dist/appstore/xcodebuild-appstore.log

# 查看 App Store 本地 export 日志。
tail -120 /Users/dong4j/Developer/1.AI/ai-incubator/Starcat/dist/appstore/xcodebuild-appstore-export.log
```

## Direct 渠道

```bash
# 进入 Starcat 主仓库。
cd /Users/dong4j/Developer/1.AI/ai-incubator/Starcat

# 查看当前本地版本 tag。
git tag --list 'v1.*' --sort=version:refname

# 查看本机签名证书。
security find-identity -v -p codesigning

# 验证 notarytool Keychain profile 是否可用。
xcrun notarytool history --keychain-profile starcat-notary

# Make 快捷入口：只生成 Direct DMG，不公证、不上传。
make package-direct VERSION=1.0.0

# Make 快捷入口：生成并公证 Direct DMG，不上传。
make package-direct-notarized VERSION=1.0.0

# 完整发布 Direct 版本：创建 tag、部署官网、打包、公证、上传并校验。
STARCAT_NOTARIZE=1 ./scripts/release-direct.sh 1.0.0

# Make 快捷入口：完整发布 Direct 版本。
make release-direct VERSION=1.0.0

# tag 已经存在时重跑 Direct 发布。
STARCAT_NOTARIZE=1 STARCAT_RELEASE_SKIP_TAG=1 ./scripts/release-direct.sh 1.0.0

# 查询 Apple notarization 提交状态。
xcrun notarytool info <submission-id> --keychain-profile starcat-notary

# notarization 已提交但等待超时后，复用 Submission ID 续跑发布。
STARCAT_NOTARIZE=1 STARCAT_RELEASE_SKIP_TAG=1 STARCAT_NOTARY_SUBMISSION_ID=<submission-id> ./scripts/release-direct.sh 1.0.0

# Make 快捷入口：复用 Submission ID 续跑正式发布。
make release-direct-retry VERSION=1.0.0 SUBMISSION_ID=<submission-id>

# Make 快捷入口：仅内部临时使用的未公证发布。
make release-direct-unnotarized VERSION=1.0.0

# 查看 Direct 构建日志。
tail -120 /Users/dong4j/Developer/1.AI/ai-incubator/Starcat/dist/direct/xcodebuild-direct.log

# 查看当前 Direct DMG SHA256。
cat /Users/dong4j/Developer/1.AI/ai-incubator/Starcat/dist/direct/downloads/Starcat-1.0.0-arm64.dmg.sha256

# 查看当前 Direct appcast。
cat /Users/dong4j/Developer/1.AI/ai-incubator/Starcat/supports/starcat-site/direct/appcast.xml

# Direct 正式发布完成后检查本机 GitHub CLI 和目标 Release。
gh auth status
gh release view v1.0.0

# 从 Direct 英文 Changelog 提取目标版本内容到临时文件后，本机创建 GitHub Release。
# 不使用 GitHub Actions；不要对已存在资产默认使用 --clobber。
gh release create v1.0.0 \
  dist/direct/downloads/Starcat-1.0.0-arm64.dmg \
  dist/direct/downloads/Starcat-1.0.0-arm64.dmg.sha256 \
  --verify-tag \
  --title "Starcat 1.0.0" \
  --notes-file "<临时发布说明文件>"

# 验证 GitHub Release 状态与资产。
gh release view v1.0.0 \
  --json tagName,name,isDraft,isPrerelease,url,assets
```

## 双渠道通用检查

```bash
# 查看主仓库工作区状态。
git status --short

# 查看 Starcat 主仓库最近一次提交。
git log -1 --oneline

# 查看当前分支。
git branch --show-current

# 查看本地与远端版本 tag。
git tag --list 'v1.*' --sort=version:refname && git ls-remote --tags origin 'v1.*'

# dev 完成整改后检查是否能快进 main；有分叉时停止，不要 rebase 或强制合并。
git status --short --branch
git worktree list --porcelain
git fetch --prune
git rev-list --left-right --count main...dev

# 获得分支操作授权且工作区干净后，切换并快进到正式发布分支。
git switch main
git merge --ff-only dev
```
