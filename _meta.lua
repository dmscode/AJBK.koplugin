local _ = require("gettext")
return {
    fullname = _("AJBK（AI 基百科）"),
    -- 发布工作流（.github/workflows/release.yml）打包时会把 tag 版本号写入此字段
    version = "0.0.0",
    description = _([[用 AI 替代维基百科：本地词典查不到的生僻字、短语，一键问 AI 得到读音与简明释义。
支持 19 家预设与自定义 AI 提供商、服务器模型列表、自定义提示词与思考模式。
默认为性能优化设计（不开思考、不带上下文、一次性小响应），适合低内存电纸书设备。]]),
}
