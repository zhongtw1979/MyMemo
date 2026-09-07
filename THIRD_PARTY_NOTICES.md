# 第三方组件与素材

- SwiftUI、AppKit、AVFoundation、Speech、CryptoKit、ServiceManagement 等是 Apple 系统框架。它们由目标系统或开发工具提供，不作为本项目源码重新授权。
- Apple 语音模型由系统服务管理，不包含在仓库或应用包中。
- FFmpeg / FFprobe 是用户可选安装的外部工具，不与本项目捆绑发布。其许可取决于用户安装的构建版本。
- 云端转写脚本为可选外部程序，不随本仓库提供，使用者需确认其许可、服务条款和凭据配置。
- App 图标由项目中的 `scripts/create-icon.swift` 绘制。界面通过系统 API 使用 SF Symbols，不分发 SF Symbols 字体或资源包。
- `Tests/MyMemoCoreTests/Fixtures/` 中的三个 MP4 文件由 FFmpeg 生成，内容为正弦波和纯色画面，不包含真实用户录音或第三方影视内容。生成命令见 `scripts/generate-test-fixtures.sh`。
