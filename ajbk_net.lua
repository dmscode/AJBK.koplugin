--[[--
AJBK 网络与解析层。

纯函数、无 UI 依赖，可在 Trapper:dismissableRunInSubprocess 的子进程中运行
（返回值只含布尔/字符串/字符串数组，可被 LuaJIT 序列化传回）。
网络相关模块在函数内部惰性加载，保持插件启动轻量（低内存设备）。
--]]

local util = require("util")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

local AjbkNet = {}

-- 释义场景：非流式响应一次性到达，单次阻塞超时需覆盖生成时间；
-- 总超时兜底，期间用户可随时点按进度框取消（子进程被终止）。
local CHAT_BLOCK_TIMEOUT = 60
local CHAT_TOTAL_TIMEOUT = 90
local MODELS_BLOCK_TIMEOUT = 15
local MODELS_TOTAL_TIMEOUT = 30

-- 内置默认值，不暴露为设置（需求决议 #5）：小响应 + 低温度，
-- 控制时延、流量与内存占用。1024 而非 300：推理模型的思考过程也计入
-- 这个额度，512 时"先解释字、再解释词"的分层回答经常被截断。
local MAX_TOKENS = 1024
local TEMPERATURE = 0.2

--- URL 工具 --------------------------------------------------------

--- 本机 / 局域网地址：这些地址上的 OpenAI 兼容服务（Ollama、LM Studio、
--- 自建 one-api）几乎都只开明文 HTTP，给它们补 https:// 等于必然握手失败。
local function isLocalHost(hostport)
    local host = hostport:match("^%[([^%]]+)%]") or hostport:match("^([^:]+)")
    if not host then
        return false
    end
    host = host:lower()
    if host == "localhost" or host == "::1" then
        return true
    end
    if host:match("^127%.") or host:match("^10%.") or host:match("^192%.168%.") then
        return true
    end
    local second = host:match("^172%.(%d+)%.")
    return second ~= nil and tonumber(second) >= 16 and tonumber(second) <= 31
end

--- 规范化用户填写的 API 根地址：
---   * 去空白与末尾斜杠；
---   * 没写协议时补协议：本机/内网补 http://，其余补 https://；
---   * 只接受 http/https，其他协议直接拒绝，免得把奇怪的东西送进 socket。
--- 返回 url；不合法时返回 nil, 错误说明。
function AjbkNet.normalizeBaseUrl(url)
    if type(url) ~= "string" then
        return nil, _("API 地址不能为空。")
    end
    url = util.trim((url:gsub("%s+", "")))
    if url == "" then
        return nil, _("API 地址不能为空。")
    end

    -- 协议少打一个斜杠（https:/host）时，后面的 "host" 会被当成主机名 "https:"，
    -- 于是用户拿到一个看起来成功、实际连不上的地址。这里直接点明笔误。
    local typo = url:match("^(%a[%w+.-]*):/([^/].*)$")
    if typo then
        return nil, T(_("API 地址格式不对：协议后面应该是 //，例如 https://api.example.com/v1（当前为 %1:/）。"),
            typo:lower())
    end

    local scheme, rest = url:match("^(%a[%w+.-]*)://(.*)$")
    if scheme then
        scheme = scheme:lower()
        if scheme ~= "http" and scheme ~= "https" then
            return nil, T(_("不支持的协议：%1://（只支持 http 与 https）。"), scheme)
        end
    else
        rest = url
    end

    local hostport = rest:match("^([^/]+)")
    if not hostport or hostport == "" then
        return nil, _("API 地址缺少主机名。")
    end
    -- 主机名只允许字母数字与 . - _（可带 :端口），或方括号包裹的 IPv6
    local host_ok = hostport:match("^[%w%.%-_]+$")
        or hostport:match("^[%w%.%-_]+%:%d+$")
        or hostport:match("^%[[%x:%.]+%]$")
        or hostport:match("^%[[%x:%.]+%]%:%d+$")
    if not host_ok then
        return nil, T(_("API 地址里的主机名不合法：%1"), hostport)
    end

    if not scheme then
        scheme = isLocalHost(hostport) and "http" or "https"
    end
    return ((scheme .. "://" .. rest):gsub("/+$", ""))
end

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

--- 剥掉 <think>…</think>（含 <thinking>、带属性的变体、未闭合残块）。
--- 不用 "<think>.-</think>" 这种模式：Lua 的 . 不跨行，而思考块几乎总是
--- 多行的，单条 gsub 只能吃掉开头那一行，整段推理会漏进释义里。
local function stripThinkBlocks(text)
    local out = {}
    local pos = 1
    while true do
        local start = text:find("<think", pos, true)
        if not start then
            out[#out + 1] = text:sub(pos)
            break
        end
        out[#out + 1] = text:sub(pos, start - 1)
        -- 按层配对：模型偶尔会把思考过程再包一层（<think>a<think>b</think>c</think>），
        -- 只找第一个 "</think" 会在正文里留下 "</think>" 和后半段思考内容
        local depth = 1
        local cursor = start
        local after
        while depth > 0 do
            -- "</think" 同时是 "</thinking" 的前缀，两种写法一起覆盖；
            -- 而 "<think" 不会匹配到 "</think"，因为第二个字符是 /
            local nopen = text:find("<think", cursor + 1, true)
            local nclose = text:find("</think", cursor + 1, true)
            if not nclose then
                break -- 没有闭合标签：余下全是思考内容，整段丢弃
            end
            if nopen and nopen < nclose then
                depth = depth + 1
                cursor = nopen
            else
                depth = depth - 1
                cursor = nclose
                if depth == 0 then
                    local gt = text:find(">", nclose, true)
                    after = gt and (gt + 1) or (nclose + #"</think>")
                end
            end
        end
        if not after then
            break
        end
        pos = after
    end
    return table.concat(out)
end

function AjbkNet.postProcess(text)
    if type(text) ~= "string" then
        return ""
    end
    text = stripThinkBlocks(text)
    -- 剥离常见 Markdown 符号
    text = text:gsub("%*%*", "")
    text = text:gsub("`+", "")
    -- 首行标题没有前置换行，得单独剥一次，否则 "# 释义" 会带着井号进查询窗
    text = text:gsub("^#+%s*", ""):gsub("\n#+%s*", "\n")
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
    return #raw > 0 and raw or _("（无响应内容）")
end

--- socket/http 的失败串是英文短标签（"closed"、"timeout"、"sink timeout"…），
--- 直接拼进提示框对用户毫无指导意义，翻成"该怎么办"。
local function describeNetError(err)
    local s = tostring(err or "")
    local low = s:lower()
    if low:find("sink timeout", 1, true) then
        return _("响应超时：服务端在总时限内没有把内容发完。")
    elseif low:find("timeout", 1, true) then
        return _("连接超时：网络不通、地址写错，或设备刚休眠断网。")
    elseif low:find("refused", 1, true) then
        return _("连接被拒绝：服务地址或端口不对，或服务没在运行。")
    elseif low:find("closed", 1, true) or low:find("reset", 1, true) then
        return _("连接被对方断开。")
    elseif low:find("resolv", 1, true) or low:find("dns", 1, true) or low:find("no address", 1, true) then
        return _("域名解析失败：检查地址拼写与网络连接。")
    elseif low:find("wantread", 1, true) or low:find("wantwrite", 1, true) then
        return _("网络读写阻塞：可能信号弱，或服务端响应太慢。")
    elseif s == "" then
        return _("未知网络错误。")
    end
    return s
end

--- 解 JSON，失败返回 nil（调用方据此区分"服务端没给 JSON"与"JSON 里没字段"）
local function decodeJson(content)
    if type(content) ~= "string" or content == "" then
        return nil
    end
    local ok, decoded = pcall(require("json").decode, content)
    if ok and type(decoded) == "table" then
        return decoded
    end
    return nil
end

--- 发请求（http 与 https 都走这里）。
--- 返回 ok, 状态码, 响应正文；连接失败时返回 false, nil, 错误信息。
local function httpRequest(headers, url, body, block_timeout, total_timeout)
    local socketutil = require("socketutil")
    -- 用 socket.http 而不是 ssl.https：LuaSocket 的 http 模块会按 URL scheme
    -- 派发到 http 或 https（socketutil 已把 ssl.https 注册进 scheme 表），
    -- 而 ssl.https 会无条件 TLS 握手，碰到 http:// 的本地服务必挂。
    local http = require("socket.http")
    local ltn12 = require("ltn12")
    local sink_tbl = {}
    socketutil:set_timeout(block_timeout, total_timeout)
    local req_ok, code_or_err = http.request{
        url = url,
        method = body and "POST" or "GET",
        headers = headers,
        source = body and ltn12.source.string(body) or nil,
        -- 必须是 socketutil.table_sink：总超时只在它里面生效，
        -- 用 ltn12.sink.table 会让 total_timeout 形同虚设
        sink = socketutil.table_sink(sink_tbl),
    }
    socketutil:reset_timeout()
    if not req_ok then
        return false, nil, describeNetError(code_or_err)
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

    local base_url, url_err = AjbkNet.normalizeBaseUrl(provider.base_url)
    if not base_url then
        return false, url_err
    end

    local thinking_params = AjbkNet.buildThinkingParams(provider.thinking_style, thinking)

    -- max_tokens / temperature 对多数模型合适，但 OpenAI o 系、gpt-5 一类
    -- 只接受默认采样参数，多传一个就 400。把"带参数"与"不带参数"都做成选项，
    -- 识别到相关报错就去掉重发一次，比让用户自己去猜哪里错了友好。
    local function makeBody(with_sampling)
        local b = {
            model = model,
            messages = {
                { role = "user", content = prompt_text },
            },
            stream = false,
        }
        if with_sampling then
            b.max_tokens = MAX_TOKENS
            b.temperature = TEMPERATURE
        end
        if thinking_params then
            for k, v in pairs(thinking_params) do
                b[k] = v
            end
        end
        return b
    end

    local function send(with_sampling)
        local ok_json, body = pcall(JSON.encode, makeBody(with_sampling))
        if not ok_json or type(body) ~= "string" then
            return nil, _("请求构造失败：无法序列化请求体。")
        end
        local headers = authHeaders({
            ["Content-Type"] = "application/json",
            ["Content-Length"] = tostring(#body),
        }, provider.api_key)
        local ok_req, code, content = httpRequest(headers,
            AjbkNet.joinURL(base_url, "chat/completions"), body,
            CHAT_BLOCK_TIMEOUT, CHAT_TOTAL_TIMEOUT)
        if not ok_req then
            return nil, T(_("网络请求失败：%1"), content)
        end
        return code, content
    end

    local code, content = send(true)
    if not code then
        return false, content
    end

    if code == 400 and type(content) == "string" then
        local low = content:lower()
        local sampling_rejected = low:find("max_tokens", 1, true)
            or low:find("max_completion_tokens", 1, true)
            or low:find("temperature", 1, true)
        if sampling_rejected then
            logger.dbg("AJBK: 服务端不接受 max_tokens/temperature，去掉后重试")
            code, content = send(false)
            if not code then
                return false, content
            end
        end
    end

    if type(code) ~= "number" or code < 200 or code >= 300 then
        -- 先看状态码再看正文：502 常常是网关吐的 HTML，先 decode 只会把
        -- "网关挂了"报成"响应解析失败"，把用户引到错误方向
        return false, T(_("HTTP %1：%2"), code or "?", extractApiError(decodeJson(content), content))
    end

    local decoded = decodeJson(content)
    if not decoded then
        return false, T(_("HTTP %1：响应解析失败"), code or "?")
    end

    local choices = decoded.choices
    local message = type(choices) == "table" and type(choices[1]) == "table"
        and choices[1].message or nil
    local out = message and message.content
    if type(out) ~= "string" or out == "" then
        if message and type(message.reasoning_content) == "string"
                and message.reasoning_content ~= "" then
            return false, _("模型只返回了思考内容，没有给出答案。\n建议在「AJBK → 思考模式」中选择关闭，或更换为非思考模型。")
        end
        return false, T(_("HTTP %1：响应中没有内容"), code or "?")
    end

    local processed = AjbkNet.postProcess(out)
    if processed == "" then
        -- 正文全被判为思考块或 Markdown 符号：不能把空串当成功，
        -- 否则原生查询窗口会弹出一个空白条目，用户只会以为插件坏了
        return false, _("模型返回的内容为空（可能全是思考过程或格式符号）。\n建议关闭思考模式，或更换模型。")
    end
    return true, processed
end

--- 获取模型列表（GET {base}/models）。
--- 同时充当连接测试：成功即说明地址与 API Key 有效。
--- 返回 ok, 模型名数组或错误描述。
function AjbkNet.fetchModels(base_url, api_key)
    local url, url_err = AjbkNet.normalizeBaseUrl(base_url)
    if not url then
        return false, url_err
    end

    local ok_req, code, content = httpRequest(authHeaders({}, api_key),
        AjbkNet.joinURL(url, "models"), nil,
        MODELS_BLOCK_TIMEOUT, MODELS_TOTAL_TIMEOUT)
    if not ok_req then
        return false, T(_("网络请求失败：%1"), content)
    end

    if type(code) ~= "number" or code < 200 or code >= 300 then
        return false, T(_("HTTP %1：%2"), code or "?", extractApiError(decodeJson(content), content))
    end

    local decoded = decodeJson(content)
    if not decoded then
        return false, T(_("HTTP %1：响应解析失败"), code or "?")
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
    logger.dbg("AJBK fetchModels:", url, #models, "models")
    return true, models
end

return AjbkNet
