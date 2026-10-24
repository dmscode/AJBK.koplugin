local _ = require("gettext")
return {
    fullname = _("AJBK（AI 基百科）"),
    -- 发布工作流（.github/workflows/release.yml）打包时会把 tag 版本号写入此字段
    version = "0.2.2",
    description = _([[用 AI 替代维基百科：本地词典查不到的生僻字、短语，一键问 AI 得到读音与简明释义。
支持 19 家预设与自定义 AI 提供商、服务器模型列表、自定义提示词模板与思考模式。
释义会带上书籍/作者/章节与前后文，选偏的片段先解释本字再解释所在词；
可指定释义语言（默认简体中文），适合低内存电纸书设备。]]),
}
