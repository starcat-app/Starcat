# SOP-手动发布命令清单

> 创建：2026-07-09
> 用途：只保留手动发布常用命令。App Store 与 Direct 两条渠道分开执行。

## App Store 渠道

```bash
# 进入 Starcat 主仓库。
cd /Users/dong4j/Developer/1.AI/ai-incubator/Starcat

# 打包 App Store archive。
STARCAT_DEVELOPMENT_TEAM=8WCUMGCWMB ./scripts/package-appstore.sh

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
cat /Users/dong4j/Developer/1.AI/ai-incubator/Starcat/pages/direct/appcast.xml
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
```
