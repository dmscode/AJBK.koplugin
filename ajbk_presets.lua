--[[--
AJBK 预设 AI 提供商（OpenAI 兼容接口）。

接入点核实于 2026-09-29，详见 docs/技术调研.md §8。
注意：多数国内提供商的国内/国际站账号与 API Key 互不通用，
因此按"提供商 × 区域"拆分为独立条目，用户选哪个条目就在对应站点注册 Key。

字段：
  id             唯一标识（同时用作设置存储键）
  name           显示名
  base_url       API 根地址（拼接 /chat/completions 与 /models）
  default_model  预填模型名（仅作初始值，用户可随时更改）
  need_key       是否需要 API Key（本地服务为 false）
  thinking_style 思考参数映射方式（见 ajbk_net.lua 的 buildThinkingParams）：
                 thinking_type | enable_thinking | reasoning_effort |
                 openrouter_reasoning | model_choice | nil
--]]

return {
    { id = "siliconflow_cn", name = "硅基流动（国内）",
      base_url = "https://api.siliconflow.cn/v1",
      default_model = "deepseek-ai/DeepSeek-V3",
      need_key = true, thinking_style = "enable_thinking" },

    { id = "siliconflow_intl", name = "硅基流动（国际）",
      base_url = "https://api.siliconflow.com/v1",
      default_model = nil,
      need_key = true, thinking_style = "enable_thinking" },

    { id = "deepseek", name = "DeepSeek",
      base_url = "https://api.deepseek.com/v1",
      default_model = "deepseek-chat",
      need_key = true, thinking_style = "model_choice",
      note = "deepseek-chat 不思考；思考需改选 deepseek-reasoner" },

    { id = "zhipu_cn", name = "智谱 GLM（国内）",
      base_url = "https://open.bigmodel.cn/api/paas/v4",
      default_model = "glm-4-flash",
      need_key = true, thinking_style = "thinking_type" },

    { id = "zhipu_intl", name = "智谱 GLM（国际 Z.ai）",
      base_url = "https://api.z.ai/api/paas/v4",
      default_model = nil,
      need_key = true, thinking_style = "thinking_type" },

    { id = "qwen_cn", name = "通义千问 百炼（国内）",
      base_url = "https://dashscope.aliyuncs.com/compatible-mode/v1",
      default_model = "qwen-turbo",
      need_key = true, thinking_style = "enable_thinking" },

    { id = "qwen_intl", name = "通义千问 百炼（国际）",
      base_url = "https://dashscope-intl.aliyuncs.com/compatible-mode/v1",
      default_model = nil,
      need_key = true, thinking_style = "enable_thinking" },

    { id = "kimi_cn", name = "Kimi（国内）",
      base_url = "https://api.moonshot.cn/v1",
      default_model = "moonshot-v1-8k",
      need_key = true, thinking_style = "model_choice" },

    { id = "kimi_intl", name = "Kimi（国际）",
      base_url = "https://api.moonshot.ai/v1",
      default_model = nil,
      need_key = true, thinking_style = "model_choice" },

    { id = "minimax_intl", name = "MiniMax（国际）",
      base_url = "https://api.minimax.io/v1",
      default_model = nil,
      need_key = true, thinking_style = "thinking_type" },

    { id = "ark_cn", name = "火山方舟 豆包（国内）",
      base_url = "https://ark.cn-beijing.volces.com/api/v3",
      default_model = nil,
      need_key = true, thinking_style = "thinking_type",
      note = "按模型名或接入点 ID 调用" },

    { id = "openrouter", name = "OpenRouter",
      base_url = "https://openrouter.ai/api/v1",
      default_model = "openai/gpt-4o-mini",
      need_key = true, thinking_style = "openrouter_reasoning" },

    { id = "openai", name = "OpenAI",
      base_url = "https://api.openai.com/v1",
      default_model = "gpt-4o-mini",
      need_key = true, thinking_style = "reasoning_effort" },

    { id = "gemini", name = "Google Gemini（OpenAI 兼容层）",
      base_url = "https://generativelanguage.googleapis.com/v1beta/openai",
      default_model = "gemini-2.5-flash",
      need_key = true, thinking_style = "reasoning_effort" },

    { id = "groq", name = "Groq",
      base_url = "https://api.groq.com/openai/v1",
      default_model = "llama-3.3-70b-versatile",
      need_key = true, thinking_style = nil },

    { id = "mistral", name = "Mistral",
      base_url = "https://api.mistral.ai/v1",
      default_model = "mistral-small-latest",
      need_key = true, thinking_style = nil },

    { id = "xai", name = "xAI Grok",
      base_url = "https://api.x.ai/v1",
      default_model = nil,
      need_key = true, thinking_style = nil },

    { id = "ollama", name = "Ollama（本地）",
      base_url = "http://localhost:11434/v1",
      default_model = nil,
      need_key = false, thinking_style = nil,
      note = "思考模型请选非思考版本；<think> 内容会被自动剥离" },

    { id = "lmstudio", name = "LM Studio（本地）",
      base_url = "http://localhost:1234/v1",
      default_model = nil,
      need_key = false, thinking_style = nil },
}
