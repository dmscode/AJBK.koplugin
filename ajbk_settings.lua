--[[--
AJBK 设置读写。

配置文件是 KOReader LuaSettings 格式的 ajbk_config.lua，位于**设置目录**
（DataStorage:getSettingsDir()），可以手工编辑或随设置目录一起同步/备份。

为什么不放插件目录：v0.1 放在插件目录里，结果是"重装/升级插件 = 用户填的
Key、提示词、模型选择全丢"——插件目录会被整体替换。现在只把
settings_file 交给插件管理器，让"删除插件"时能顺手清理配置。

使用的键：
  providers  已配置提供商表（数组，含 api_key）
  active     当前生效提供商 id
  models     各提供商选中模型（id → 模型名 映射表）
  prompt     自定义提示词（不存在即用默认）
  thinking   思考模式：off | low | medium | high
--]]

local logger = require("logger")
local util = require("util")
local _ = require("gettext")

local CONFIG_FILENAME = "ajbk_config.lua"

local AjbkSettings = {
    CONFIG_FILENAME = CONFIG_FILENAME,
}

--- 默认提示词。分层解释的要求放在 prompt 里而不是硬编码进代码：
--- 用户想换成"只给一句话释义"时，改模板即可，不必改插件。
AjbkSettings.DEFAULT_PROMPT = table.concat({
    "你是词典，照《现代汉语词典》排版：一个读音一段，段内列义项。只输出条目本身，不要开场白、不要总结。",
    "",
    "选区：{{selection}}",
    "语境：{{title}}｜{{authors}}｜{{chapter}}",
    "原文：{{sentence}}",
    "前后文：{{context}}",
    "{{lookup_note}}",
    "",
    "格式示例一（同一个读音、两类不同的意思，各自成段）：",
    "【词条】harbor",
    "【读音】/ˈhɑːbə/",
    "【释义】① 港口 ② 避难所",
    "",
    "【读音】/ˈhɑːbə/",
    "【释义】① 庇护，掩护 ② 怀有（想法、感情）",
    "",
    "格式示例二（两个读音，读音跟着上下文走：原文是「出差」，所以 chāi 排第一）：",
    "【词条】差",
    "【读音】chāi（本句）",
    "【释义】① 派遣，奉命外出：出差",
    "",
    "【读音】chà",
    "【释义】① 不好，差劲：成绩差 ② 不同，相差：差不多",
    "",
    "格式示例三（原文是「这孩子长高了不少」，长 在这里读 zhǎng）：",
    "【词条】长",
    "【读音】zhǎng（本句）",
    "【释义】① 生长：长高 ② 增加：增长",
    "",
    "【读音】cháng",
    "【释义】① 两端之间距离大：长路 ② 时间久：长期",
    "",
    "要求：",
    "- 先在心里判断这个字词在原文里是什么词性（名词/动词/形容词/副词/量词/成语/专名…），",
    "  用它决定读哪个音、取哪条义项；但不要把词性写出来，输出里不要出现「词性」二字。",
    "- 第一行写【词条】，之后每个读音一段，每段两行：【读音】【释义】，段与段之间空一行；",
    "  后面的段落不要再写【词条】。",
    "- 先看原文判断这个字在这里读什么音，把那个读音排第一段并在后面加（本句）；",
    "  拿不准就不加，不要标错。没有原文时不加，只有一个读音也不加。",
    "- 确实有几个读音才分几段，最多三段；同一个读音只能出现一次，它下面的义项都放进那一段里，"
        .. "不要为同一读音再开一段；拿不准就只写一段。",
    "- 【读音】中文拼音音节间空一格（diàn huà），日文写假名，西文写音标并带斜杠。",
    "- 【释义】最多三条，每条二十字以内，用①②③编号（两条以上才编号）；只写词义，"
        .. "不讲用法、出处，义项里不出现词条本身（写「美玉」不写「瑰」）。",
    "- 只有当选中的是单个字、而这个字不能单独成词时（瑰、葡、徘），才在最后补一段【所在词】："
        .. "先写【所在词】词，再照同样两行写读音、释义。能单独成词的字不要补。",
    "- 不要输出书名、作者、章节。",
    "{{fragment_note}}",
}, "\n")

--- 查询没有原文/上下文时（查词窗口按钮、手动查询）注入。
AjbkSettings.LOOKUP_NOTE = "本次没有原文和上下文：不标（本句），按常用读音与义项写，把最常用的读音放第一段。"

--- 选区类型对应的补充说明，由 {{fragment_note}} 注入到提示词末尾。
--- 不套 _()：这是写给模型看的指令，和提示词模板一样用户可自行改写。
AjbkSettings.SELECTION_HINTS = {
    single = "这次只选中了一个字符：先写它的条目；若它不能单独成词，再补一段【所在词】，"
        .. "必须是原文里真实出现的词，找不到就省略，能单独成词的字不要补。",
    long = "这次选中了一整段文字，不是一个词。【词条】照抄这段文字本身，不要缩成其中一个词；"
        .. "【读音】这一行只写 —；【词性】写 短语（确实是完整句子时写 句子）；"
        .. "【释义】用一句话写整段文字的意思，只写一条不要编号。",
    cut = "这次选区只截取了单词的一部分（左右被字母粘着），不要解释那半截字母："
        .. "直接在【词条】写它所属的完整单词，整段都照完整单词填。",
    complete = "这次选区是一个完整词条：只写它自己的段落，不要补【所在词】，也不要追加注释、例句或补充说明。",
    maybe = "这次选区左右都紧贴文字，可能是一个完整的词，也可能只是长词的一半。先判断："
        .. "若它本身是常用词，只写它自己的段落，不要补充；"
        .. "只有明显只是半个词（原文是「计算机」而选区只有「计算」）时，才补一段【所在词】。",
}

--- 目标语言：决定释义用哪种语言回答。--- 目标语言：决定释义用哪种语言回答。
--- 只给两个常用项 + 自定义：语言名是自然语言，模型自己就能理解
--- “日本語”/“繁體中文” 这类任意写法，不必枚举一长串。
AjbkSettings.TARGET_LANGUAGES = {
    { label = "中文", value = "中文" },
    { label = "英文", value = "英文" },
}

--- 模板占位符。label/desc 保持未翻译：菜单里再 _()，
--- 避免模块加载时就固定了语言。
AjbkSettings.PLACEHOLDERS = {
    { key = "selection", label = "选择内容", desc = "实际选中的文字（已清洗标点）" },
    { key = "selection_chars", label = "选中字数", desc = "选区字符数，帮助模型判断是否只选了一两个字" },
    { key = "context", label = "上下文", desc = "前后各若干词，选中位置用【】标出" },
    { key = "context_before", label = "前文", desc = "选区之前的文字" },
    { key = "context_after", label = "后文", desc = "选区之后的文字" },
    { key = "sentence", label = "所在句子", desc = "选区扩展到句末标点的整句" },
    { key = "fragment_note", label = "选区提示",
      desc = "按选区类型自动生成的指令：完整词条时为「别多写」，单字/切半/存疑时要求分层解释" },
    { key = "lookup_note", label = "查询模式说明",
      desc = "没有原文与上下文时（查词窗口、手动查询）自动注入，告诉模型别去猜语境" },
    { key = "selection_kind", label = "选区类型", desc = "单字 / 词片段 / 可能是半个词 / 长短语 / 完整词条" },
    { key = "title", label = "书名", desc = "当前文档标题" },
    { key = "authors", label = "作者", desc = "当前文档作者" },
    { key = "series", label = "丛书", desc = "丛书名，没有则为空" },
    { key = "language", label = "文档语言", desc = "文档元数据里的语言代码" },
    { key = "chapter", label = "章节", desc = "当前页所属目录项标题" },
    { key = "page", label = "页码", desc = "当前页" },
    { key = "pages", label = "总页数", desc = "全书页数" },
    { key = "percent", label = "阅读进度", desc = "形如 42%" },
    { key = "date", label = "日期", desc = "今天，带星期" },
    { key = "time", label = "时间", desc = "当前时刻" },
    { key = "provider", label = "提供商", desc = "当前 AI 提供商名称" },
    { key = "model", label = "模型", desc = "当前模型名" },
    { key = "target_language", label = "目标语言", desc = "释义用哪种语言回答（设置 → 目标语言）" },
}

local config_path = nil -- 显式指定的配置文件完整路径
local instance = nil    -- LuaSettings 实例，惰性创建

--- 显式指定配置文件完整路径；须在首次访问设置前调用
function AjbkSettings.setConfigPath(path)
    config_path = path
    instance = nil
end

--- 配置文件位置：设置目录下的 ajbk_config.lua
function AjbkSettings.getConfigPath()
    if not config_path then
        local DataStorage = require("datastorage")
        config_path = DataStorage:getSettingsDir() .. "/" .. CONFIG_FILENAME
    end
    return config_path
end

--- 把 v0.1 留在插件目录里的配置搬到设置目录，搬完删旧文件，
--- 免得两份配置各写各的。
local function migrateLegacyConfig(plugin_path, target)
    if not plugin_path then
        return
    end
    local legacy = plugin_path .. "/" .. CONFIG_FILENAME
    if util.fileExists(target) or not util.fileExists(legacy) then
        return
    end
    local f = io.open(legacy, "r")
    if not f then
        return
    end
    local content = f:read("*a")
    f:close()
    if not content or content == "" then
        return
    end
    util.writeToFile(content, target, true)
    if util.fileExists(target) then
        os.remove(legacy)
        logger.info("AJBK: 配置已从插件目录迁移到", target)
    end
end

--- 插件装载时调用一次。返回配置文件路径，供插件管理器"删除插件"时清理。
function AjbkSettings.init(plugin_path)
    local DataStorage = require("datastorage")
    local target = DataStorage:getSettingsDir() .. "/" .. CONFIG_FILENAME
    migrateLegacyConfig(plugin_path, target)
    AjbkSettings.setConfigPath(target)
    return target
end

local function S()
    if not instance then
        local LuaSettings = require("luasettings")
        instance = LuaSettings:open(AjbkSettings.getConfigPath())
    end
    return instance
end

--- 目标文件是否真的可写：以追加模式打开一次，立刻关闭（不写入，mtime 不变）。
--- 探针必须打在被写的那个文件上——只探目录会漏掉"文件变只读、目录仍可写"
--- 这种最常见的情况（同步工具、备份脚本会把配置文件改成只读）。
--- LuaSettings:flush 内部用 util.writeToFile，写失败只 logger.warn，调用方拿不到信号。
local function fileWritable(path)
    local f = io.open(path, "a")
    if not f then
        return false
    end
    f:close()
    return true
end

--- 落盘。返回是否成功，调用方据此提示用户，而不是一律说"已保存"。
local function save()
    local path = AjbkSettings.getConfigPath()
    S():flush()
    if not fileWritable(path) then
        logger.warn("AJBK: 配置写入失败（配置文件不可写）", path)
        return false
    end
    return true
end

--- 提供商 ----------------------------------------------------------

--- 返回已配置提供商数组（设置中的引用；改动后请调用 saveProviders）
function AjbkSettings.getProviders()
    return S():readSetting("providers", {})
end

function AjbkSettings.saveProviders(providers)
    S():saveSetting("providers", providers)
    return save()
end

function AjbkSettings.getProvider(id)
    for _, p in ipairs(AjbkSettings.getProviders()) do
        if p.id == id then
            return p
        end
    end
end

--- 添加提供商；第一个自动设为当前。
--- 返回 provider；id 已存在时 nil, "duplicate"；写盘失败时 nil, "unwritable"。
--- 落盘结果必须回传，否则只读目录下会"提示已添加、重启后消失"。
function AjbkSettings.addProvider(provider)
    local providers = AjbkSettings.getProviders()
    for _, p in ipairs(providers) do
        if p.id == provider.id then
            return nil, "duplicate"
        end
    end
    providers[#providers + 1] = provider
    if not AjbkSettings.saveProviders(providers) then
        return nil, "unwritable"
    end
    if #providers == 1 then
        AjbkSettings.setActiveId(provider.id)
    end
    return provider
end

function AjbkSettings.updateProvider(id, patch)
    local p = AjbkSettings.getProvider(id)
    if not p then
        return false
    end
    for k, v in pairs(patch) do
        p[k] = v
    end
    return AjbkSettings.saveProviders(AjbkSettings.getProviders())
end

--- 删除提供商。成功返回被删的 provider；不存在返回 nil, "not_found"；
--- 写盘失败返回 nil, "unwritable"（与"不存在"分开，调用方才能给出对的提示）。
function AjbkSettings.removeProvider(id)
    local providers = AjbkSettings.getProviders()
    for i, p in ipairs(providers) do
        if p.id == id then
            table.remove(providers, i)
            if not AjbkSettings.saveProviders(providers) then
                return nil, "unwritable"
            end
            local models = AjbkSettings.getModels()
            if models[id] ~= nil then
                models[id] = nil
                S():saveSetting("models", models)
            end
            if AjbkSettings.getActiveId() == id then
                -- 删掉的正是当前提供商：接续到剩下的第一家，否则整个插件会
                -- 陷入"未配置提供商"状态，用户还得再进两层菜单才能恢复
                local next_id = providers[1] and providers[1].id
                if next_id then
                    AjbkSettings.setActiveId(next_id)
                else
                    S():delSetting("active")
                end
            end
            return p
        end
    end
    return nil, "not_found"
end

--- 当前提供商 ------------------------------------------------------

function AjbkSettings.getActiveId()
    return S():readSetting("active")
end

function AjbkSettings.setActiveId(id)
    S():saveSetting("active", id)
    return save()
end

function AjbkSettings.getActiveProvider()
    return AjbkSettings.getProvider(AjbkSettings.getActiveId())
end

--- 模型 ------------------------------------------------------------

function AjbkSettings.getModels()
    return S():readSetting("models", {})
end

function AjbkSettings.getModel(id)
    return AjbkSettings.getModels()[id]
end

function AjbkSettings.setModel(id, model)
    local models = AjbkSettings.getModels()
    models[id] = model
    S():saveSetting("models", models)
    return save()
end

--- 用户显式选择的模型优先，否则用预设的 default_model
function AjbkSettings.getEffectiveModel(provider)
    return AjbkSettings.getModel(provider.id) or provider.default_model
end

--- 提示词 ----------------------------------------------------------

function AjbkSettings.getPrompt()
    return S():readSetting("prompt") or AjbkSettings.DEFAULT_PROMPT
end

function AjbkSettings.isPromptCustom()
    return S():has("prompt")
end

function AjbkSettings.setPrompt(text)
    S():saveSetting("prompt", text)
    return save()
end

function AjbkSettings.resetPrompt()
    S():delSetting("prompt")
    return save()
end

--- 渲染提示词模板。
--- 规则：
---   * 一行里所有占位符都渲染为空 → 整行（连同换行）删掉，于是
---     "章节：{{chapter}}" 在手动查询时不会留下一行空壳；
---   * 模板里有、vars 里**根本不存在**的键原样保留，方便用户发现拼写错误；
---     但「已知占位符只是这次没有值」按空串处理，这样 buildPrompt(字符串)
---     这类只填了 selection 的旧调用不会漏出一堆 {{title}}；
---   * {{word}} 是 {{selection}} 的历史别名，老模板不用改。
function AjbkSettings.renderPrompt(prompt, vars)
    if type(prompt) ~= "string" then
        return ""
    end
    vars = vars or {}

    local known = { word = true }
    for _, ph in ipairs(AjbkSettings.PLACEHOLDERS or {}) do
        known[ph.key] = true
    end

    local function value(key)
        if key == "word" then
            key = "selection"
        end
        local v = vars[key]
        if v == nil then
            return known[key] and "" or nil
        end
        if type(v) == "number" then
            v = tostring(v)
        end
        return type(v) == "string" and v or ""
    end

    local out = {}
    for line in (prompt .. "\n"):gmatch("(.-)\n") do
        local total, empty = 0, 0
        local rendered = line:gsub("{{([%w_]+)}}", function(key)
            local v = value(key)
            if v == nil then
                return "{{" .. key .. "}}"
            end
            total = total + 1
            if v == "" then
                empty = empty + 1
            end
            return v
        end)
        if total == 0 or total > empty then
            out[#out + 1] = rendered
        end
    end

    return (table.concat(out, "\n"):gsub("^\n+", ""):gsub("\n+$", ""))
end

--- 把变量渲染成最终提示词。传字符串时按旧行为包装成 { selection = word }。
function AjbkSettings.buildPrompt(vars)
    if type(vars) == "string" then
        vars = { selection = vars }
    end
    return AjbkSettings.renderPrompt(AjbkSettings.getPrompt(), vars)
end

--- 思考模式 --------------------------------------------------------

function AjbkSettings.getThinking()
    return S():readSetting("thinking", "off")
end

--- 思考参数的映射方式。预设插件自带 thinking_style，自定义提供商要能手动指定，
--- 否则"思考模式"档位对它毫无作用（智谱 GLM 一类默认思考，正文会被挤空）。
--- key 与 ajbk_net.buildThinkingParams 的 style 分支一一对应。
AjbkSettings.THINKING_STYLES = {
    { key = nil, label = "无（不发送）" },
    { key = "thinking_type", label = "thinking.type（智谱 GLM / MiniMax / 方舟）" },
    { key = "enable_thinking", label = "enable_thinking（DeepSeek / Kimi / 硅基流动）" },
    { key = "reasoning_effort", label = "reasoning_effort（OpenAI / Gemini / Mistral）" },
    { key = "openrouter_reasoning", label = "reasoning.effort（OpenRouter）" },
    { key = "model_choice", label = "不支持（靠选模型区分思考与非思考）" },
}

function AjbkSettings.setThinking(level)
    S():saveSetting("thinking", level)
    return save()
end

--- 目标语言 --------------------------------------------------------
-- 默认中文：读书多半想用母语看释义，而不是被外文原文带着走

function AjbkSettings.getTargetLanguage()
    return S():readSetting("target_language", "中文")
end

function AjbkSettings.setTargetLanguage(value)
    S():saveSetting("target_language", value)
    return save()
end

--- 是否为预设项（中文 / 英文）；不在列表里的都算自定义
function AjbkSettings.isPresetLanguage(value)
    for index, item in ipairs(AjbkSettings.TARGET_LANGUAGES) do
        if item.value == value then
            return true
        end
    end
    return false
end

--- 菜单显示用：自定义值原样显示
function AjbkSettings.getTargetLanguageLabel()
    local value = AjbkSettings.getTargetLanguage()
    for index, item in ipairs(AjbkSettings.TARGET_LANGUAGES) do
        if item.value == value then
            return item.label
        end
    end
    return value
end

return AjbkSettings
