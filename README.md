# 极简聊天

SwiftUI iPhone 私聊应用，Cloudflare Workers + D1 + R2 后端。支持用户名和密码注册、好友申请、文字、图片与最多 60 秒语音；聊天界面打开时定时刷新。

消息和附件由服务端授权访问，并通过 HTTPS 传输；本版本不提供端到端加密、推送通知或密码找回。不要把签名证书、密码、令牌提交到仓库。

## iOS

GitHub Actions 在 macOS 上使用 Xcode 构建未签名 IPA。未签名 IPA 需通过适合设备的签名方式重新签名才能安装。

## 服务端

`server/` 包含数据库迁移、Worker、Cloudflare 配置与集成测试。部署所需资源为独立 D1 数据库和私有 R2 存储桶。运行 `npm ci` 和 `npm test` 可验证核心权限与消息流程。

