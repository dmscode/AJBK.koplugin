# -*- coding: utf-8 -*-
"""AJBK.koplugin 桌面端验证：语法检查 + 纯函数/网络层单元测试（需 pip install lupa）。

用法：python tests/ajbk_test.py
路径无关（本地与 CI 均可运行）；不依赖 KOReader 与真实网络——
KOReader 侧的 util/logger/json/socket 全部用桩替代，网络响应由测试注入。
"""
import os
import sys
import io
import shutil
import tempfile

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace")
from lupa import LuaRuntime

# 本脚本位于 <插件根>/tests/ 下，插件根即上一级目录
BASE = os.path.dirname(os.path.dirname(os.path.abspath(__file__))).replace("\\", "/")
TMP = tempfile.gettempdir().replace("\\", "/")

lua = LuaRuntime()

# ---- 1. 语法检查（等价 luac -p）----
files = ["_meta.lua", "ajbk_presets.lua", "ajbk_settings.lua", "ajbk_context.lua",
         "ajbk_net.lua", "main.lua"]
for f in files:
    r = lua.execute(f'''
        local f, err = loadfile([[{BASE}/{f}]])
        if f then return "OK" else return "FAIL: " .. tostring(err) end
    ''')
    print(f"SYNTAX {f}: {r}")
    if r != "OK":
        sys.exit(1)

# ---- 1b. 标识符拼写（Ajkb / Ajkb 肉眼无法区分，历史上真写错过两次）----
CORRECT = "Aj" + "bk" + "Settings"
WRONG = "Aj" + "kb" + "Settings"
misspelled = []
for f in files:
    with open(os.path.join(BASE, f), encoding="utf-8") as fp:
        if WRONG in fp.read():
            misspelled.append(f)
print(f"SPELLING {'OK' if not misspelled else 'FAIL: ' + ', '.join(misspelled)}")
if misspelled:
    sys.exit(1)

# ---- 2. 可执行模块的单元测试 ----
# 迁移用例要在真实目录间搬文件；Lua 侧没有 mkdir，交给 Python 建好传进去
LEGACY_DIR = tempfile.mkdtemp(prefix="ajbk_legacy_").replace("\\", "/")
lua.execute(r'''
-- KOReader 依赖桩 -------------------------------------------------

-- 真实的 ffi/util.template 按 %%1 字面量替换；写成 gsub("%" .. i) 会得到
-- 模式 "%1"（捕获组引用），一调用就报 invalid capture index。
package.preload["ffi/util"] = function()
    return { template = function(s, ...)
        local args = {...}
        return (tostring(s):gsub("%%(%d+)", function(n)
            local v = args[tonumber(n)]
            if v == nil then return "" end
            return tostring(v)
        end))
    end }
end

package.preload["gettext"] = function()
    return function(s) return s end
end

package.preload["logger"] = function()
    local noop = function() end
    return { dbg = noop, info = noop, warn = noop, err = noop }
end

-- util 桩：只实现插件真正用到的纯函数，语义对齐 KOReader util.lua
package.preload["util"] = function()
    local util = {}
    local UTF8 = "[%z\1-\127\194-\244][\128-\191]*"
    function util.splitToChars(s)
        local t = {}
        for c in s:gmatch(UTF8) do t[#t + 1] = c end
        return t
    end
    function util.trim(s)
        return (s:gsub("^%s+", ""):gsub("%s+$", ""))
    end
    function util.cleanupSelectedText(s)
        if type(s) ~= "string" then return "" end
        s = s:gsub("^%s+", ""):gsub("%s+$", "")
        s = s:gsub(" *\n *", " ")
        return (s:gsub("%s+", " "))
    end
    function util.isCJKChar(c)
        if #c < 3 then return false end
        local b1, b2, b3 = c:byte(1, 3)
        local code = (b1 - 0xE0) * 0x1000 + (b2 - 0x80) * 0x40 + (b3 - 0x80)
        return code >= 0x4E00 and code <= 0x9FFF
    end
    function util.hasCJKChar(s)
        for c in s:gmatch(UTF8) do
            if util.isCJKChar(c) then return true end
        end
        return false
    end
    function util.fileExists(path)
        local f = io.open(path, "r")
        if f then f:close() return true end
        return false
    end
    function util.writeToFile(data, path)
        local f = io.open(path, "w")
        if not f then return false end
        f:write(data)
        f:close()
        return true
    end
    return util
end

-- LuaSettings / DataStorage 桩
package.preload["luasettings"] = function()
    local LuaSettings = {}
    local stores = {}
    function LuaSettings:open(path)
        stores[path] = stores[path] or {}
        local st = stores[path]
        local o = { file = path }
        function o:readSetting(key, default)
            local v = st[key]
            if v ~= nil then return v end
            return default
        end
        function o:saveSetting(key, v) st[key] = v end
        function o:delSetting(key) st[key] = nil end
        function o:has(key) return st[key] ~= nil end
        function o:flush() end
        return o
    end
    return LuaSettings
end
package.preload["datastorage"] = function()
    return { getSettingsDir = function() return [[@@TMP@@]] end }
end

-- 网络与 JSON 桩：由测试注入响应，覆盖 chatCompletion/fetchModels 全链路
-- queue 用于"第一次 400、重试成功"这类多轮场景；calls 记录每次请求，
-- 便于断言重试时的请求体确实去掉了 max_tokens/temperature
http_state = { ok = true, code = 200, body = "", last = nil, queue = nil, calls = {} }
package.preload["socket.http"] = function()
    return {
        request = function(req)
            http_state.last = req
            http_state.calls[#http_state.calls + 1] = req
            local resp = http_state
            if http_state.queue and #http_state.queue > 0 then
                resp = table.remove(http_state.queue, 1)
            end
            if req and req.sink and resp.body then
                req.sink(resp.body)
            end
            return resp.ok, resp.code, {}, resp.body
        end,
    }
end
package.preload["socketutil"] = function()
    return {
        set_timeout = function() end,
        reset_timeout = function() end,
        -- 真实实现里只有这个 sink 会执行 total_timeout
        table_sink = function(t)
            return function(chunk)
                if chunk then
                    t[#t + 1] = chunk
                    return 1
                end
                return nil
            end
        end,
    }
end
package.preload["ltn12"] = function()
    return { source = { string = function(s)
        local sent = false
        return function()
            if sent then
                return nil
            end
            sent = true
            return s
        end
    end } }
end

json_state = { encode_result = "{}", decode_result = nil, decode_error = false, encoded = {} }
package.preload["json"] = function()
    return {
        encode = function(tbl)
            -- 记下每次请求体的原文，重试逻辑要靠它断言"确实去掉了采样参数"
            json_state.encoded[#json_state.encoded + 1] = tbl
            return json_state.encode_result
        end,
        decode = function()
            if json_state.decode_error then error("invalid json") end
            return json_state.decode_result
        end,
    }
end

package.preload["ui/widget/container/widgetcontainer"] = function()
    -- 只保留 extend：菜单构建用不到真正的 widget 生命周期
    local WidgetContainer = {}
    function WidgetContainer:extend(spec)
        local cls = {}
        for k, v in pairs(spec or {}) do cls[k] = v end
        cls.__index = cls
        return cls
    end
    return WidgetContainer
end
package.preload["ui/uimanager"] = function()
    local noop = function() end
    return { show = noop, close = noop, scheduleIn = noop, nextTick = noop, setDirty = noop }
end

results = {}
local function check(name, ok, detail)
    results[#results + 1] = (ok and "PASS " or "FAIL ") .. name
        .. (detail and (" | " .. tostring(detail)) or "")
end

-- 预设 --------------------------------------------------------------

local presets = dofile([[@@BASE@@/ajbk_presets.lua]])
check("presets 数量=19", #presets == 19, #presets)
local ids = {}
local shape_ok = true
for _, p in ipairs(presets) do
    if ids[p.id] then shape_ok = false end
    ids[p.id] = true
    if type(p.id) ~= "string" or type(p.name) ~= "string" or type(p.base_url) ~= "string"
        or p.base_url:find("https?://") ~= 1 then shape_ok = false end
    if p.thinking_style ~= nil and p.thinking_style ~= "thinking_type"
        and p.thinking_style ~= "enable_thinking" and p.thinking_style ~= "reasoning_effort"
        and p.thinking_style ~= "openrouter_reasoning" and p.thinking_style ~= "model_choice" then
        shape_ok = false
    end
end
check("presets 结构/唯一 id", shape_ok)

-- 设置 --------------------------------------------------------------

local S = dofile([[@@BASE@@/ajbk_settings.lua]])
S.setConfigPath([[@@TMP@@/ajbk_config_test.lua]])
check("配置路径注入", S.getConfigPath():find("ajbk_config_test%.lua") ~= nil)
check("默认提示词含占位符", S.DEFAULT_PROMPT:find("{{selection}}", 1, true) ~= nil)
check("默认提示词是词典排版", S.DEFAULT_PROMPT:find("【读音】", 1, true) ~= nil and S.DEFAULT_PROMPT:find("（本句）", 1, true) ~= nil)
local has_lookup_note = false
for _i, ph in ipairs(S.PLACEHOLDERS) do if ph.key == "lookup_note" then has_lookup_note = true end end
check("占位符含查询模式说明", has_lookup_note and #S.PLACEHOLDERS >= 22, tostring(#S.PLACEHOLDERS))

local p1 = S.addProvider({ id = "a1", name = "甲", base_url = "https://x/v1", api_key = "", default_model = "m1" })
local p_dup = S.addProvider({ id = "a1", name = "重复", base_url = "https://x/v1" })
check("addProvider 返回 provider", type(p1) == "table" and p1.id == "a1")
check("addProvider 去重", p_dup == nil)
check("首个自动激活", S.getActiveId() == "a1" and S.getActiveProvider().name == "甲")

S.updateProvider("a1", { api_key = "sk-test" })
check("updateProvider", S.getProvider("a1").api_key == "sk-test")
check("getEffectiveModel 预设回退", S.getEffectiveModel(S.getProvider("a1")) == "m1")
S.setModel("a1", "m2")
check("setModel 覆盖", S.getEffectiveModel(S.getProvider("a1")) == "m2")

S.addProvider({ id = "b2", name = "乙", base_url = "https://y/v1", api_key = "k" })
S.setActiveId("b2")
check("切换激活", S.getActiveProvider().name == "乙")
S.removeProvider("b2")
-- 删掉当前提供商后自动接续到剩下的第一家，避免插件进入"未配置"状态
check("removeProvider 自动接续", S.getActiveId() == "a1")

-- 提示词模板
local tpl = "书：{{title}}\n章：{{chapter}}\n词：{{selection}}\n上下文：{{context}}\n未知：{{typo}}"
local rendered = S.renderPrompt(tpl, {
    title = "", chapter = "", selection = "饕餮",
    context = "贪于饮食【饕餮】者也",
})
check("renderPrompt 空值删整行", rendered
    == "词：饕餮\n上下文：贪于饮食【饕餮】者也\n未知：{{typo}}", rendered)
check("renderPrompt word 别名", S.renderPrompt("查{{word}}", { selection = "饕餮" }) == "查饕餮")
S.setPrompt("查询{{selection}}并解释。")
check("buildPrompt 占位符", S.buildPrompt({ selection = "饕餮" }) == "查询饕餮并解释。")
check("buildPrompt 百分号安全", S.buildPrompt({ selection = "100%纯" }) == "查询100%纯并解释。")
check("buildPrompt 兼容字符串入参", S.buildPrompt("饕餮") == "查询饕餮并解释。")
-- 字符串入参只填了 selection，但默认模板里还有 {{title}} 等已知占位符；
-- 它们必须按空渲染，否则用户会看到一屏字面 {{title}}
local str_default = S.buildPrompt("饕餮")
check("buildPrompt 字符串入参不漏占位符", str_default:find("{{", 1, true) == nil, str_default)
S.resetPrompt()
check("resetPrompt", not S.isPromptCustom() and S.getPrompt() == S.DEFAULT_PROMPT)
-- 占位符齐全的 vars（真实调用里 AjkbContext.build 总是键齐全）
local dvars = {}
for _, ph in ipairs(S.PLACEHOLDERS) do dvars[ph.key] = "" end
dvars.selection = "饕餮"
dvars.selection_chars = "2"
local default_rendered = S.renderPrompt(S.DEFAULT_PROMPT, dvars)
check("默认提示词无空壳行", default_rendered:find("书籍", 1, true) == nil
    and default_rendered:find("饕餮", 1, true) ~= nil
    and default_rendered:find("{{", 1, true) == nil, default_rendered)

S.setThinking("high")
check("thinking set/get", S.getThinking() == "high")
S.setThinking("off")

-- 目标语言：决定释义语言，默认中文 ------------------------------
check("目标语言默认中文", S.getTargetLanguage() == "中文")
S.setTargetLanguage("英文")
check("目标语言可改", S.getTargetLanguage() == "英文" and S.getTargetLanguageLabel() == "英文")
check("目标语言进入提示词", S.renderPrompt("用{{target_language}}解释", { target_language = "英文" }) == "用英文解释")
-- 自定义：任意语言名都直接进提示词，菜单里原样显示
S.setTargetLanguage("日文")
check("目标语言自定义", S.getTargetLanguage() == "日文" and not S.isPresetLanguage("日文"))
check("目标语言自定义标签", S.getTargetLanguageLabel() == "日文")
check("目标语言自定义进提示词", S.renderPrompt("用{{target_language}}解释", { target_language = "日文" }) == "用日文解释")
check("目标语言预设判定", S.isPresetLanguage("中文") and S.isPresetLanguage("英文"))
S.setTargetLanguage("中文")

-- 菜单构建：这些函数是纯数据生成，能脱离 KOReader 直接跑。
-- 之前 for _, x in ipairs() 把模块顶部的 local _ = require("gettext") 遮成数字，
-- 一点菜单就 attempt to call a number 并崩掉整个 reader.lua，这里必须挡住。
package.path = [[@@BASE@@/?.lua;]] .. package.path
local AJBK = dofile([[@@BASE@@/main.lua]])
local tl_menu = AJBK:genTargetLanguageMenu()
-- 两项预设（中文/英文）+ 自定义 + 一条说明
check("目标语言菜单项数", #tl_menu == #S.TARGET_LANGUAGES + 2, #tl_menu)
local tl_texts_ok = true
for i = 1, #tl_menu do
    local item = tl_menu[i]
    if type(item.text) ~= "string" and type(item.text_func) ~= "function" then
        tl_texts_ok = false
    end
end
check("目标语言菜单文案非空", tl_texts_ok)
check("目标语言菜单是单选项", tl_menu[1].radio == true and type(tl_menu[1].checked_func) == "function")
local custom_item = tl_menu[#S.TARGET_LANGUAGES + 1]
check("目标语言有自定义项", custom_item.radio == true
    and type(custom_item.text_func) == "function"
    and type(custom_item.callback) == "function")
local ph_menu = AJBK:genPlaceholderMenu()
check("占位符菜单项数", #ph_menu == #S.PLACEHOLDERS + 2, #ph_menu)
local ph_texts_ok = true
for i = 3, #ph_menu do
    if not tostring(ph_menu[i].text):find("{{", 1, true) then ph_texts_ok = false end
end
check("占位符菜单带 {{key}}", ph_texts_ok)
local tm = AJBK:genThinkingMenu()
check("思考模式菜单可构建", #tm >= 5, #tm)

-- 旧配置迁移（v0.1 把配置写在插件目录，v0.2 起改到设置目录）-----------
-- 迁移逻辑要真的搬文件、搬完删旧文件，且目标已存在时不能覆盖用户新配置。
local function readFile(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local c = f:read("*a")
    f:close()
    return c
end

local legacy_dir = [[@@LEGACY@@]]
local target_cfg = [[@@TMP@@/]] .. "ajbk_config.lua"
os.remove(target_cfg)
os.remove(legacy_dir .. "/ajbk_config.lua")
local legacy_content = [[return { providers = { { id = "old" } }, active = "old" }]]
local lf = io.open(legacy_dir .. "/ajbk_config.lua", "w")
lf:write(legacy_content)
lf:close()

local moved_path = S.init(legacy_dir)
check("旧配置迁移 目标路径在设置目录", moved_path == target_cfg, moved_path)
check("旧配置迁移 内容一致", readFile(target_cfg) == legacy_content)
check("旧配置迁移 旧文件已删", readFile(legacy_dir .. "/ajbk_config.lua") == nil)

-- 目标已存在时不再迁移（否则重装旧版插件会覆盖掉当前配置）
local lf2 = io.open(legacy_dir .. "/ajbk_config.lua", "w")
lf2:write([[return { providers = { { id = "older" } } }]])
lf2:close()
S.setConfigPath(target_cfg)
S.init(legacy_dir)
check("旧配置迁移 不覆盖已存在的目标", readFile(target_cfg) == legacy_content
    and readFile(legacy_dir .. "/ajbk_config.lua") ~= nil)

os.remove(target_cfg)
os.remove(legacy_dir .. "/ajbk_config.lua")
-- 迁移用例改过 config_path，恢复成这份测试自己的路径
S.setConfigPath([[@@TMP@@/ajbk_config_test.lua]])

-- 上下文采集 --------------------------------------------------------

local C = dofile([[@@BASE@@/ajbk_context.lua]])

-- 造一个 crengine 风格的最小文档对象：每个方法都能按需给出上下文
local function fakeDoc(opts)
    opts = opts or {}
    local doc = {}
    function doc:getDocumentProps() return { title = opts.title } end
    function doc:getCurrentPage() return 7 end
    function doc:getPageCount() return 100 end
    function doc:getSelectedWordContext() return opts.prev or "", opts.next or "" end
    function doc:getTextFromXPointers(a, b) return (opts.chars and opts.chars[a .. ">" .. b]) or "" end
    function doc:extendXPointersToSentenceSegment() return { text = opts.sentence or "" } end
    function doc:getPrevVisibleChar() return opts.left_pos end
    function doc:getNextVisibleChar() return opts.right_pos end
    return doc
end

local full_doc = fakeDoc({
    title = "山海经",
    prev = "贪于饮食",
    next = "者也，为物",
    sentence = "贪于饮食，冒于货贿，天下谓之饕餮。",
    left_pos = "L",
    right_pos = "R",
    chars = { ["L>p0"] = "食", ["p1>R"] = "者" },
})
local ui = {
    document = full_doc,
    doc_props = { title = "山海经", authors = "佚名" },
    toc = { getTocTitleOfCurrentPage = function() return "北山经" end },
}
local sel = { text = "饕餮", pos0 = "p0", pos1 = "p1", sboxes = {} }
local vars = C.build(ui, "饕餮", sel, { name = "深度求索" }, "deepseek-chat")
check("上下文 context 拼接", vars.context == "贪于饮食【饕餮】者也，为物", vars.context)
check("上下文 sentence", vars.sentence == "贪于饮食，冒于货贿，天下谓之饕餮。")
check("上下文 元数据", vars.title == "山海经" and vars.authors == "佚名" and vars.chapter == "北山经")
check("上下文 进度", vars.page == "7" and vars.pages == "100" and vars.percent == "7%")
check("上下文 日期非空", #vars.date > 0 and #vars.time > 0)
check("上下文 provider/model", vars.provider == "深度求索" and vars.model == "deepseek-chat")
check("上下文 选区类型（汉字两侧粘连=存疑）",
    vars.selection_kind == "可能是半个词" and vars.fragment_note:find("【所在词】", 1, true) ~= nil,
    vars.selection_kind .. " / " .. vars.fragment_note)

-- 无坐标（查词窗口按钮、手动查询）：变量齐全但上下文为空，模板整行会被删掉
local bare = C.build(ui, "饕餮", nil, nil, nil)
check("上下文 无坐标时为空",
    bare.context == "" and bare.sentence == "" and bare.selection_kind == "完整词条")
check("上下文 键齐全", bare.selection == "饕餮" and bare.provider == "" and bare.model == "")
check("上下文 无原文时提示别猜语境", bare.lookup_note ~= "" and bare.lookup_note:find("没有原文", 1, true) ~= nil, bare.lookup_note)
check("上下文 有原文时不插入该提示", vars.lookup_note == "", vars.lookup_note)

-- PDF/无 crengine 方法：全部 pcall 兜底，不应抛错
local empty = C.build({ document = {} }, "饕餮", { pos0 = "p0", pos1 = "p1" }, nil, nil)
check("上下文 缺方法不崩", empty.context == "" and empty.sentence == "" and empty.title == "")

-- 单个汉字、两侧不粘连：给出"只选中一个字符"的提示
local single_doc = fakeDoc({ left_pos = nil, right_pos = nil })
local single = C.build({ document = single_doc }, "饕", { pos0 = "p0", pos1 = "p1" }, nil, nil)
check("选区自检 单字",
    single.selection_kind == "单字" and single.fragment_note:find("一个字符", 1, true) ~= nil,
    single.selection_kind .. " / " .. single.fragment_note)

-- 西文两侧都不粘连 = 完整单词，不应报警
local latin_doc = fakeDoc({ left_pos = "L", right_pos = "R", chars = { ["L>p0"] = " ", ["p1>R"] = " " } })
local latin = C.build({ document = latin_doc }, "elegy", { pos0 = "p0", pos1 = "p1" }, nil, nil)
check("选区自检 西文完整词只写四行",
    latin.selection_kind == "完整词条" and latin.fragment_note:find("不要补【所在词】", 1, true) ~= nil,
    latin.selection_kind .. " / " .. latin.fragment_note)

-- 句末标点不是词内字符：。、！？ 夹在两侧说明这是完整的词，不是被切开的半个词
local punct_doc = fakeDoc({
    left_pos = "L", right_pos = "R",
    chars = { ["L>p0"] = "。", ["p1>R"] = "，" },
})
local punct = C.build({ document = punct_doc }, "你好", { pos0 = "p0", pos1 = "p1" }, nil, nil)
check("选区自检 中文标点不误报", punct.selection_kind == "完整词条", punct.selection_kind)

-- 带变音符号的西文单词：é 属于词内字符，两侧粘连才报警
local accent_doc = fakeDoc({
    left_pos = "L", right_pos = "R",
    chars = { ["L>p0"] = "é", ["p1>R"] = " " },
})
local accent = C.build({ document = accent_doc }, "cafe", { pos0 = "p0", pos1 = "p1" }, nil, nil)
check("选区自检 变音字母算词内字符",
    accent.selection_kind == "词片段" and accent.fragment_note:find("完整单词", 1, true) ~= nil,
    accent.selection_kind .. " / " .. accent.fragment_note)

-- 手动查询（无坐标）：只能按字数判断，单字同样给出分层指令
local manual_single = C.build(ui, "打", nil, nil, nil)
check("选区自检 手动单字", manual_single.selection_kind == "单字"
    and manual_single.fragment_note:find("【所在词】", 1, true) ~= nil, manual_single.selection_kind)

-- 完整词条时，提示文字必须明确禁止追加内容（否则模型爱补一句）
check("选区自检 完整词条不许追加",
    vars.selection_kind == "可能是半个词" and latin.fragment_note:find("不要追加", 1, true) ~= nil)

-- 整句/长短语：含句读标点或足够长时，不能让模型从里面挑一个词
local sentence_doc = fakeDoc({ sentence = "他拿起电话，却不知道该说什么。" })
local sentence_vars = C.build({ document = sentence_doc }, "他拿起电话，却不知道该说什么。",
    { pos0 = "p0", pos1 = "p1" }, nil, nil)
check("选区类型 整句算长短语", sentence_vars.selection_kind == "长短语"
    and sentence_vars.fragment_note:find("照抄", 1, true) ~= nil, sentence_vars.selection_kind)

-- 回归：多字节标点写进 Lua 字符类会按字节误命中其他汉字
-- （「漏」的 UTF-8 里含 0xBC，正好是「！」的中间字节），4 字日文词必须仍是完整词条
local jp_vars = C.build({ document = fakeDoc({}) }, "木漏れ日", { pos0 = "p0", pos1 = "p1" }, nil, nil)
check("选区类型 日文词不被误判", jp_vars.selection_kind == "完整词条", jp_vars.selection_kind)

-- 专名也按完整词条处理（7 字，无标点）
local name_vars = C.build({ document = fakeDoc({}) }, "中华人民共和国", { pos0 = "p0", pos1 = "p1" }, nil, nil)
check("选区类型 长专名算完整词条", name_vars.selection_kind == "完整词条", name_vars.selection_kind)

-- 长选区不该被截断：查询正文就是用户要查的东西
local long_text = string.rep("甲", 500)
local long_vars = C.build(ui, long_text, nil, nil, nil)
check("选区不截断", long_vars.selection == long_text and long_vars.selection_chars == "500",
    tostring(#long_vars.selection) .. "/" .. long_vars.selection_chars)

-- 网络与解析 --------------------------------------------------------

local N = dofile([[@@BASE@@/ajbk_net.lua]])

check("joinURL 常规", N.joinURL("https://api.deepseek.com/v1", "models") == "https://api.deepseek.com/v1/models")
check("joinURL 尾斜杠", N.joinURL("https://host/v1beta/openai/", "chat/completions") == "https://host/v1beta/openai/chat/completions")

check("normalizeBaseUrl 去尾斜杠", N.normalizeBaseUrl("https://host/v1/") == "https://host/v1")
check("normalizeBaseUrl 补 https", N.normalizeBaseUrl(" host:8080/v1 ") == "https://host:8080/v1")
check("normalizeBaseUrl 保留 http", N.normalizeBaseUrl("http://localhost:11434/v1") == "http://localhost:11434/v1")
local nrm, nerr = N.normalizeBaseUrl("ftp://host/v1")
check("normalizeBaseUrl 拒绝非 http 协议", nrm == nil and nerr:find("ftp", 1, true) ~= nil)
check("normalizeBaseUrl 空值", N.normalizeBaseUrl("") == nil)
check("normalizeBaseUrl 缺主机", N.normalizeBaseUrl("https://") == nil)
-- 本机/内网服务只开明文 HTTP，补 https 等于保证握手失败
check("normalizeBaseUrl 本机默认 http", N.normalizeBaseUrl("localhost:11434") == "http://localhost:11434")
check("normalizeBaseUrl 内网默认 http", N.normalizeBaseUrl("192.168.1.9:8080/v1") == "http://192.168.1.9:8080/v1")
-- 协议少打一个斜杠是常见笔误，不能被当成合法主机名 "https:"
local typo_url, typo_err = N.normalizeBaseUrl("https:/host/v1")
check("normalizeBaseUrl 拒绝单斜杠笔误", typo_url == nil and typo_err:find("//", 1, true) ~= nil, typo_err)

local t1 = N.buildThinkingParams("thinking_type", "off")
check("thinking_type off", t1.thinking.type == "disabled")
local t2 = N.buildThinkingParams("thinking_type", "low")
check("thinking_type low→enabled", t2.thinking.type == "enabled")
local t3 = N.buildThinkingParams("enable_thinking", "off")
check("enable_thinking off", t3.enable_thinking == false)
local t4 = N.buildThinkingParams("enable_thinking", "medium")
check("enable_thinking medium→true", t4.enable_thinking == true)
check("reasoning_effort off→nil", N.buildThinkingParams("reasoning_effort", "off") == nil)
local t6 = N.buildThinkingParams("reasoning_effort", "high")
check("reasoning_effort high", t6.reasoning_effort == "high")
local t7 = N.buildThinkingParams("openrouter_reasoning", "off")
check("openrouter off", t7.reasoning.enabled == false)
local t8 = N.buildThinkingParams("openrouter_reasoning", "low")
check("openrouter low", t8.reasoning.effort == "low")
check("未映射样式→nil", N.buildThinkingParams("model_choice", "off") == nil)

local pp = N.postProcess
check("postProcess 思考块", pp("<think>推理</think>饕餮，tāo tiè。") == "饕餮，tāo tiè。")
check("postProcess 多行思考块", pp("<think>\n先想\n再想\n</think>释义") == "释义")
check("postProcess 多段思考块", pp("前<think>甲</think>中<thinking>乙</thinking>后") == "前中后")
check("postProcess 未闭合思考", pp("<think>推理中…") == "")
check("postProcess 未闭合多行思考", pp("<think>\n甲\n乙\n丙") == "")
check("postProcess Markdown", pp("**饕餮**：`tāo tiè`") == "饕餮：tāo tiè")
check("postProcess 标题行", pp("\n# 释义\n大鼎。\n") == "释义\n大鼎。")
-- 首行标题没有前置换行，旧实现只认 "\n#"，于是 "# 释义" 带着井号进查询窗
check("postProcess 首行标题", pp("# 释义\n大鼎。") == "释义\n大鼎。", pp("# 释义\n大鼎。"))
-- 嵌套 think：模型偶尔把思考再包一层，只找第一个 </think 会漏出半个闭合标签
check("postProcess 嵌套思考块", pp("前<think>中<think>内</think>尾</think>后") == "前后",
    pp("前<think>中<think>内</think>尾</think>后"))
check("postProcess 空行压缩", pp("甲\n\n\n\n\n乙") == "甲\n\n乙")
check("postProcess 空输入", pp(nil) == "")

-- chatCompletion / fetchModels：注入假响应
local provider = { id = "p", name = "P", base_url = "https://host/v1", api_key = "sk-x", thinking_style = "enable_thinking" }
local function reset_http(ok, code, body)
    http_state.ok, http_state.code, http_state.body = ok, code, body
    -- 每个用例从干净状态开始：重试逻辑靠 queue/calls，残留会让断言互相污染
    http_state.queue = nil
    http_state.calls = {}
    json_state.encoded = {}
end

reset_http(true, 200, "{}")
json_state.decode_result = { choices = { { message = { content = "饕餮 tāo tiè，贪食的恶兽。" } } } }
local ok_ok, out = N.chatCompletion(provider, "m", "prompt", "off")
check("chatCompletion 成功", ok_ok == true and out == "饕餮 tāo tiè，贪食的恶兽。", out)
check("chatCompletion URL 与鉴权", http_state.last.url == "https://host/v1/chat/completions"
    and http_state.last.headers.Authorization == "Bearer sk-x", http_state.last.url)

json_state.decode_result = { choices = { { message = { content = "", reasoning_content = "思考中…" } } } }
local ok_ro, err_ro = N.chatCompletion(provider, "m", "prompt", "off")
check("chatCompletion 只有思考内容", ok_ro == false and err_ro:find("思考内容", 1, true) ~= nil)

json_state.decode_result = { choices = { { message = { content = "<think>整段思考</think>" } } } }
local ok_blank, err_blank = N.chatCompletion(provider, "m", "prompt", "off")
check("chatCompletion 后处理为空即失败", ok_blank == false and err_blank:find("为空", 1, true) ~= nil)

reset_http(true, 401, "{}")
json_state.decode_result = { error = { message = "invalid api key" } }
local ok_401, err_401 = N.chatCompletion(provider, "m", "prompt", "off")
check("chatCompletion HTTP 错误", ok_401 == false and err_401:find("401", 1, true) ~= nil
    and err_401:find("invalid api key", 1, true) ~= nil, err_401)

-- 200 但正文不是 JSON：这才是"解析失败"；非 2xx 现在优先按状态码报错
reset_http(true, 200, "<html>bad gateway</html>")
json_state.decode_error = true
local ok_bad, err_bad = N.chatCompletion(provider, "m", "prompt", "off")
check("chatCompletion 解析失败", ok_bad == false and err_bad:find("解析失败", 1, true) ~= nil, err_bad)
json_state.decode_error = false

-- 502 + HTML 错误页：应该报状态码与片段，而不是"解析失败"
reset_http(true, 502, "<html>bad gateway</html>")
local ok_502, err_502 = N.chatCompletion(provider, "m", "prompt", "off")
check("chatCompletion 网关错误页", ok_502 == false and err_502:find("502", 1, true) ~= nil
    and err_502:find("解析失败", 1, true) == nil, err_502)

reset_http(false, "timeout", "")
local ok_net, err_net = N.chatCompletion(provider, "m", "prompt", "off")
-- 底层错误串是英文短标签，必须翻成人话再给用户看
check("chatCompletion 网络失败", ok_net == false and err_net:find("超时", 1, true) ~= nil, err_net)

-- o 系 / gpt-5 不接受 max_tokens+temperature：400 后去掉重发一次
reset_http(true, 200, "{}")
http_state.queue = {
    { ok = true, code = 400, body = '{"error":{"message":"Unsupported parameter: temperature"}}' },
    { ok = true, code = 200, body = "{}" },
}
json_state.decode_result = { choices = { { message = { content = "饕餮" } } } }
local ok_retry, out_retry = N.chatCompletion(provider, "m", "prompt", "off")
check("chatCompletion 采样参数被拒后重试", ok_retry == true and #http_state.calls == 2
    and json_state.encoded[1].max_tokens ~= nil
    and json_state.encoded[#json_state.encoded].max_tokens == nil,
    tostring(#http_state.calls) .. " 次请求")

reset_http(true, 200, "{}")
local ok_url, err_url = N.chatCompletion({ base_url = "ftp://host/v1" }, "m", "prompt", "off")
check("chatCompletion 拒绝坏地址", ok_url == false and err_url:find("ftp", 1, true) ~= nil)

json_state.decode_result = { data = { { id = "b-model" }, { id = "a-model" } } }
reset_http(true, 200, "{}")
local ok_models, models = N.fetchModels("https://host/v1/", "sk-x")
check("fetchModels 排序", ok_models == true and models[1] == "a-model" and models[2] == "b-model")
check("fetchModels 鉴权与地址", http_state.last.headers.Authorization == "Bearer sk-x"
    and http_state.last.url == "https://host/v1/models", http_state.last.url)

json_state.decode_result = { data = {} }
local ok_empty, empty_models = N.fetchModels("https://host/v1", "sk-x")
check("fetchModels 空列表", ok_empty == true and #empty_models == 0)
'''.replace("@@BASE@@", BASE).replace("@@TMP@@", TMP).replace("@@LEGACY@@", LEGACY_DIR))

results = lua.globals().results
shutil.rmtree(LEGACY_DIR, ignore_errors=True)
n_fail = 0
for i in range(1, len(results) + 1):
    line = results[i]
    print(line)
    if line.startswith("FAIL"):
        n_fail += 1
print(f"\n== {len(results)} checks, {n_fail} failed ==")
sys.exit(1 if n_fail else 0)
