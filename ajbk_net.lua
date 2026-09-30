--[[--
AJBK 网络与解析层。

纯函数、无 UI 依赖，可在 Trapper:dismissableRunInSubprocess 的子进程中运行
（返回值只含布尔/字符串/字符串数组，可被 LuaJIT 序列化传回）。
网络相关模块在函数内部惰性加载，保持插件启动轻量（低内存设备）。
--]]

local T = require("ffi/util").template

local AjbkNet = {}

-- 释义场景：非流式响应一次性到达，单次阻塞超时需覆盖生成时间；
-- 超时上限兜底，期间用户可随时点按进度框取消（子进程被终止）。
local CHAT_BLOCK_TIMEOUT = 60
local CHAT_TOTAL_TIMEOUT = 90
local MODELS_BLOCK_TIMEOUT = 15
local MODELS_TOTAL_TIMEOUT = 30

-- 内置默认值，不暴露为设置（需求决议 #5）：小响应 + 低温度，
-- 控制时延、流量与内存占用。
local MAX_TOKENS = 300
local TEMPERATURE = 0.2

--- URL 工具 --------------------------------------------------------

--- 拼接 base_url 与路径，兼容末尾带 / 的 base_url（Gemini 兼容层是活例）
function AjbkNet.joinURL(base_url, path)
    return (base_url:gsub("/+$", "")) .. "/" .. path
end

--- 思考参数映射 ----------------------------------------------------
--- AJBK 统一抽象为 off / low / medium / high，按提供商映射为具体参数。
--- 各家约定核实于 2026-09-29，详见 docs/技术调研.md §9.1。

function AjbkNet.buildThinkingParams(style, level)
    if style == "thinking_type" then
        -- 智谱 GLM / MiniMax / 火山方舟
        if level == "off" then
            return { thinking = { type = "disabled" } }
        end
        return { thinking = { type = "enabled" } }
    elseif style == "enable_thinking" then
        -- Qwen（百炼）/ SiliconFlow
        if level == "off" then
            return { enable_thinking = false }
        end
        return { enable_thinking = true }
    elseif style == "reasoning_effort" then
        -- OpenAI / Gemini 兼容层。关闭时不发参数：非推理模型本就不思考，
        -- o 系列无法真正关闭，靠 max_tokens 与进度框取消兜底。
        if level == "off" then
            return nil
        end
        return { reasoning_effort = level }
    elseif style == "openrouter_reasoning" then
        -- 注意 exclude:true 只是隐藏思维链、不省 token，这里用 enabled:false 真关
        if level == "off" then
            return { reasoning = { enabled = false } }
        end
        return { reasoning = { effort = level } }
    end
    -- model_choice（DeepSeek/Kimi，通过选模型控制）或未映射：不发参数
    return nil
end

--- 响应后处理 ------------------------------------------------------
--- 思考内容永不显示（需求决议）：只取 message.content，
--- 思考块与 Markdown 符号一律剥离，输出纯文本适配 e-ink 原生窗口。

function AjbkNet.postProcess(text)
    if type(text) ~= "string" then
        return ""
    end
    -- 剥离思考块（含未闭合残块）
    text = text:gsub("<think>.-</think>", "")
    text = text:gsub("<think>.*$", "")
    -- 剥离常见 Markdown 符号
    text = text:gsub("%*%*", "")
    text = text:gsub("`+", "")
    text = text:gsub("\n#+%s*", "\n")
    -- 压缩空白
    text = text:gsub("[ \t]+\n", "\n")
    text = text:gsub("\n%s*\n+", "\n\n")
    text = text:gsub("^%s+", ""):gsub("%s+$", "")
    return text
end

--- 请求与解析 ------------------------------------------------------

local function extractApiError(decoded, raw)
    local function str(v)
        if type(v) == "string" then
            return v
        end
        if type(v) == "table" and type(v.message) == "string" then
            return v.message
        end
        return nil
    end
    if type(decoded) == "table" then
        local e = str(decoded.error) or str(decoded.message) or str(decoded.msg)
        if e then
            return e
        end
    end
    raw = raw or ""
    if #raw > 200 then
        raw = raw:sub(1, 200) .. "…"
    end
    return #raw > 0 and raw or "（无响应内容）"
end

--- 发 HTTPS/HTTP 请求。返回 ok, code, content；
--- 连接失败时返回 false, nil, 错误信息。
local function httpRequest(headers, url, body, block_timeout, total_timeout)
    local socketutil = require("socketutil")
    local ltn12 = require("ltn12")
    local https = require("ssl.https")
    local sink_tbl = {}
    socketutil:set_timeout(block_timeout, total_timeout)
    local req_ok, code_or_err = https.request{
        url = url,
        method = body and "POST" or "GET",
        headers = headers,
        source = body and ltn12.source.string(body) or nil,
        sink = ltn12.sink.table(sink_tbl),
    }
    socketutil:reset_timeout()
    if not req_ok then
        return false, nil, tostring(code_or_err)
    end
    return true, code_or_err, table.concat(sink_tbl)
end

local function authHeaders(headers, api_key)
    if api_key and api_key ~= "" then
        headers["Authorization"] = "Bearer " .. api_key
    end
    return headers
end

--- 发起一次释义请求。
--- 返回 ok(boolean), 成功时为释义纯文本 / 失败时为错误描述。
function AjbkNet.chatCompletion(provider, model, prompt_text, thinking)
    local JSON = require("json")

    local body_tbl = {
        model = model,
        messages = {
            { role = "user", content = prompt_text },
        },
        stream = false,
        max_tokens = MAX_TOKENS,
        temperature = TEMPERATURE,
    }
    local thinking_params = AjbkNet.buildThinkingParams(provider.thinking_style, thinking)
    if thinking_params then
        for k, v in pairs(thinking_params) do
            body_tbl[k] = v
        end
    end

    local ok_json, body = pcall(JSON.encode, body_tbl)
    if not ok_json or type(body) ~= "string" then
        return false, "请求构造失败"
    end

    local headers = authHeaders({
        ["Content-Type"] = "application/json",
        ["Content-Length"] = tostring(#body),
    }, provider.api_key)

    local ok_req, code, content = httpRequest(headers,
        AjbkNet.joinURL(provider.base_url, "chat/completions"), body,
        CHAT_BLOCK_TIMEOUT, CHAT_TOTAL_TIMEOUT)
    if not ok_req then
        return false, T("网络请求失败：%1", content)
    end

    local ok_decode, decoded = pcall(JSON.decode, content)
    if not ok_decode or type(decoded) ~= "table" then
        return false, T("HTTP %1：响应解析失败", code or "?")
    end
    if type(code) ~= "number" or code < 200 or code >= 300 then
        return false, T("HTTP %1：%2", code or "?", extractApiError(decoded, content))
    end

    local choices = decoded.choices
    local message = type(choices) == "table" and type(choices[1]) == "table"
        and choices[1].message or nil
    local out = message and message.content
    if type(out) ~= "string" or out == "" then
        if message and type(message.reasoning_content) == "string"
                and message.reasoning_content ~= "" then
            return false, "模型只返回了思考内容，没有给出答案。\n建议在「AJBK → 思考模式」中选择关闭，或更换为非思考模型。"
        end
        return false, T("HTTP %1：响应中没有内容", code or "?")
    end
    return true, AjbkNet.postProcess(out)
end

--- 获取模型列表（GET {base}/models）。
--- 同时充当连接测试：成功即说明地址与 API Key 有效。
--- 返回 ok, 模型名数组或错误描述。
function AjbkNet.fetchModels(base_url, api_key)
    local JSON = require("json")

    local headers = {}
    if api_key and api_key ~= "" then
        headers["Authorization"] = "Bearer " .. api_key
    end
    local ok_req, code, content = httpRequest(headers,
        AjbkNet.joinURL(base_url, "models"), nil,
        MODELS_BLOCK_TIMEOUT, MODELS_TOTAL_TIMEOUT)
    if not ok_req then
        return false, T("网络请求失败：%1", content)
    end

    local ok_decode, decoded = pcall(JSON.decode, content)
    if not ok_decode or type(decoded) ~= "table" then
        return false, T("HTTP %1：响应解析失败", code or "?")
    end
    if type(code) ~= "number" or code < 200 or code >= 300 then
        return false, T("HTTP %1：%2", code or "?", extractApiError(decoded, content))
    end

    local data = decoded.data
    if type(data) ~= "table" then
        data = decoded.models
    end
    local models = {}
    if type(data) == "table" then
        for _, item in pairs(data) do
            local id
            if type(item) == "table" then
                id = item.id or item.name or item.model
            elseif type(item) == "string" then
                id = item
            end
            if type(id) == "string" and id ~= "" then
                models[#models + 1] = id
            end
        end
    end
    table.sort(models)
    return true, models
end

return AjbkNet
