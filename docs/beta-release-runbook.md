# Work Tempo 试用分发流程

## 发布门槛

2026-09-09维护者明确改为立即公开现有试用包，取代原先等待朋友跨机验收的发布顺序。以GitHub预发布及公开官网分发，明确标注未公证、跨机验证待完成，不冒充正式签名软件。首版使用手动下载更新。

## 冻结源代码并构建

- 只对当前 Git 跟踪文件创建无扩展属性的源码快照；包含确认的本地修复，但不要修改、暂存或覆盖其他任务的工作区改动。
- 排除用户配置、Agent 会话、缓存、签名私钥、用户专属 Xcode 文件。保留 Package.resolved 与合法框架符号链接。
- 在独立临时目录解开快照，使用独立 DerivedData 和 SourcePackages 副本；不得直接打包 /Applications 内的开发构建。
- 构建参数：DynamicIsland scheme，Release，generic/platform=macOS，arm64，CODE_SIGNING_ALLOWED=NO，CODE_SIGNING_REQUIRED=NO，-disableAutomaticPackageResolution，-onlyUsePackageVersionsFromResolvedFile。此试用标签为2.3.3-beta.1，应用版本2.3.3，构建号1258。
- 保持Release应用身份com.Ebullioscopic.Atoll；Debug是com.Ebullioscopic.Atoll.dev。不能在用户当前安装上切换身份或重置偏好。未来统一身份需单独设计备份和迁移。

## 验证与打包

1. 冻结源码运行 `python3 -m unittest discover -s tests -p 'test_*.py'`。
2. 在Vendor/ShortcutLauncher运行现有 `./scripts/verify-delivery.sh`（其自清理仅限快照中的新生成构建；不发布HostDemo）。
3. 主工程用ATOLL_UNIT_TESTING=1运行DynamicIslandTests；不在用户运行环境启用真实快捷键或业务配置测试。
4. 使用 `node scripts/package-beta.mjs APP SOURCE_TAR SOURCE_PACKAGES OUTPUT_DIR LABEL BASE_COMMIT`。OUTPUT_DIR必须不存在；脚本不安装、启动、上传或公开软件。
5. 打包脚本收集许可证，核对Release图标、版本、架构、依赖、外部符号链接和禁止携带的配置，嵌套代码由内向外临时签名，验证签名后生成DMG、对应源码ZIP、清单和SHA-256。
6. 挂载最终DMG，把应用复制到新临时目录，弹出镜像，再核对签名、完整性和独立启动；测试模式启动不代表正常功能或Gatekeeper已通过。
7. 朋友按beta-installation.md完成干净Mac验证。未公证包的系统安全拒绝应如实记录；不关闭系统保护，不把本机开发运行成功当作分发成功。

## 当前公开试用流程

- 检查来源快照、实际安装包、源代码与版本标签匹配；建立可追溯提交，保留授权的修改和完整许可证，不覆盖公开仓库历史。
- 上传DMG、对应源码、SHA256SUMS和说明为GitHub预发布。先验证资产可下载、大小及哈希一致。
- 复用现有Sites项目；设置NEXT_PUBLIC_DOWNLOAD_URL、RELEASE_VERSION、RELEASE_SIZE、RELEASE_SHA256、RELEASE_NOTARIZED对应的NEXT_PUBLIC_变量。未公证必须为false，不填伪造链接。
- 官网展示Apple Silicon范围及试用限制；按用户批准改为公众访问并重新构建/发布，在匿名场景验证网页和下载。
- 现有社交分享图仍是旧“薪跳”封面；用户未单独要求换分享封面时不重绘。公开分享前明确告知这一遗留项。
- 正式Developer ID签名、公证及Sparkle自动更新是后续独立步骤，不能用临时签名或SHA-256替代苹果公证。
