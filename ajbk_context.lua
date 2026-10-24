--[[--
AJBK 上下文采集：把"用户此刻到底想查什么"所需的现场信息整理成模板变量。

电子墨水屏上拖选很容易只选中一个字、多带一个标点，或者整体偏了半个词，
而单看选区字符串根本判断不出词性与语境。这里尽量向模型提供：
  选区本身 + 前后各若干词 + 所在整句 + 书籍元数据 + 章节与进度，
外加一条"选区疑似不完整"的自检提示，让模型自己决定要不要分层解释。

crengine 专有方法一律经 pcall：PDF/图片型文档没有这些方法，
对应变量留空，模板里那一整行会被 ajbk_settings.renderPrompt 整行删掉。
--]]

local util = require("util")
local _ = require("gettext")
local T = require("ffi/util").template
-- settings 不反向依赖本模块，这里不会构成循环 require
local AjbkSettings = require("ajbk_settings")

local AjbkContext = {}

-- 前后文各取几个词。crengine 按可见词边界向外扩，中文实际按字扩，
-- 6 个词对判断词性够用，又不至于把整段正文塞进提示词。
local CONTEXT_WORDS = 6
local MAX_CONTEXT_CHARS = 120
local MAX_SENTENCE_CHARS = 200
-- 被查询的正文不当作"上下文"处理：它是用户真正要查的东西，截断会让模型
-- 解释的和结果窗口标题里显示的不是同一段文字。1000 字符只是防呆上限。
local MAX_SELECTION_CHARS = 1000

--- 选区类型的显示名。key 与 AjbkSettings.SELECTION_HINTS 一一对应。
--- 存中文原文、用时再 _()，避免模块加载时把界面语言钉死。
local SELECTION_KIND_LABELS = {
    single = "单字",
    cut = "词片段",
    maybe = "可能是半个词",
    long = "长短语",
    complete = "完整词条",
}

--- 句读标点。必须逐个 plain 查找：Lua 的字符类是按字节匹配的，
--- 把「。」「！」这类多字节标点写进 [..] 会连别的汉字字节一起命中
--- （例如「漏」的 UTF-8 字节里含 0xBC，正对上「！」的中间字节）。
local SENTENCE_PUNCT = { "。", "！", "？", "；", "：", "，", "、", ",", ";", "!", "?" }

local function hasSentencePunct(text)
    for _, p in ipairs(SENTENCE_PUNCT) do
        if text:find(p, 1, true) then
            return true
        end
    end
    return false
end

--- 整句/长短语：不该被当成一个词去解释，否则模型会自作主张从里面挑一个词。
--- 判据：含句读标点，或汉字 10 个以上，或西文 4 个词以上。
--- 阈值故意偏高：实测 5~8 字的成语、俗语、诗句由"完整词条"处理得更好
--- （能给出拼音与「成语」词性），"长短语"会把读音留成 —。
local function isLongSelection(text, n)
    if type(text) ~= "string" or text == "" then
        return false
    end
    if hasSentencePunct(text) then
        return true
    end
    if util.hasCJKChar(text) then
        return n >= 10
    end
    local words = 0
    for _ in text:gmatch("%S+") do
        words = words + 1
    end
    return words >= 4
end

--- 星期名在调用时取翻译：模块加载时取值会把界面语言固定在启动那一刻
--- （切换语言后菜单/提示不跟着变），与 PLACEHOLDERS 的约定保持一致。
local function weekdayName(wday)
    local names = { _("周日"), _("周一"), _("周二"), _("周三"), _("周四"), _("周五"), _("周六") }
    return names[wday] or ""
end

--- 字符数（按 UTF-8 码位数，不是字节数）
local function charCount(s)
    if type(s) ~= "string" or s == "" then
        return 0
    end
    return #util.splitToChars(s)
end

--- 压掉换行与连续空白，再按字符截断。提示词是单行上下文，
--- 原样带入换行会把模板结构撑乱。
local function clip(s, max)
    if type(s) ~= "string" then
        return ""
    end
    s = util.trim((s:gsub("%s+", " ")))
    if s == "" then
        return ""
    end
    if charCount(s) <= max then
        return s
    end
    return table.concat(util.splitToChars(s), "", 1, max) .. "…"
end

--- 取 UTF-8 字符串首字符的码位。自己解一遍而不是依赖 ffi/util，
--- 是为了让纯 Lua 测试环境也能跑（这里只需要判断"是不是标点"）。
local function codepoint(c)
    local b1 = c:byte(1)
    if not b1 then
        return nil
    end
    if b1 < 0x80 then
        return b1
    end
    local n = b1 >= 0xF0 and 4 or (b1 >= 0xE0 and 3 or 2)
    local cp = b1 % (2 ^ (8 - n - 1))
    for i = 2, n do
        local bi = c:byte(i)
        if not bi then
            return nil
        end
        cp = cp * 64 + (bi % 64)
    end
    return cp
end

--- 是否"词内字符"。用来判断选区边缘是否被切断（切开了说明用户没选全）。
--- 不能直接用 util.isCJKChar：它的范围含 CJK 标点（。、！？…），
--- 于是"他说你好。"里"你好"左右两侧都被当成粘连，完整两字词天天被误报。
local function isWordChar(c)
    if type(c) ~= "string" or c == "" then
        return false
    end
    if c:match("^%s$") then
        return false
    end
    local cp = codepoint(c)
    if not cp then
        return false
    end
    if cp < 0x80 then
        return c:match("^[%a%d]$") ~= nil
    end
    -- 非 ASCII：排除标点/符号区段，其余（含变音字母 é/ü/đ 与 CJK 汉字）都算词内字符
    if cp >= 0x2000 and cp <= 0x206F then return false end -- 常用标点
    if cp >= 0x3000 and cp <= 0x303F then return false end -- CJK 标点 。、《》
    if cp >= 0xFE30 and cp <= 0xFE4F then return false end -- CJK 兼容形式
    if cp >= 0xFF01 and cp <= 0xFF20 then return false end -- 全角 ！＂＃…＠
    if cp >= 0xFF3B and cp <= 0xFF40 then return false end -- 全角 ［＼］＾＿｀
    if cp >= 0xFF5B and cp <= 0xFF65 then return false end -- 全角 ｛｜｝～ 等
    return true
end

--- 调文档对象上的方法；方法不存在（PDF 引擎）或报错都当作"没有这项信息"。
--- 只取前两个返回值：本模块只用到 getSelectedWordContext 的 (prev, next)。
local function callDoc(doc, method, ...)
    if not doc or type(doc[method]) ~= "function" then
        return nil
    end
    local ok, a, b = pcall(doc[method], doc, ...)
    if not ok then
        return nil
    end
    return a, b
end

local function textBetween(doc, pos0, pos1)
    if not pos0 or not pos1 then
        return ""
    end
    local t = callDoc(doc, "getTextFromXPointers", pos0, pos1)
    return type(t) == "string" and t or ""
end

--- 元数据：阅读器在打开文档时已解析好一份放在 ui.doc_props，
--- 文件管理器路径没有它，再向文档对象要一次。
local function docProps(ui, doc)
    local props = ui and ui.doc_props
    if type(props) ~= "table" then
        props = callDoc(doc, "getDocumentProps")
    end
    return type(props) == "table" and props or {}
end

--- 采集模板变量。返回的 table 键齐全，没有取到的值为空串
--- （空串正是 renderPrompt 删整行的依据，不要用 nil）。
--- @param ui 当前 ReaderUI（可为 nil：文件管理器手动查询）
--- @param selection 已清洗的选区文本
--- @param selected_text ReaderHighlight.selected_text（含 pos0/pos1/sboxes；可为 nil）
--- @param provider 当前提供商
--- @param model 当前模型名
function AjbkContext.build(ui, selection, selected_text, provider, model)
    local doc = ui and ui.document
    -- 只在空白上规整一下，不再截断正文；字数按完整选区的字符数报，别报截断后的长度
    local selection_text = type(selection) == "string" and util.trim((selection:gsub("%s+", " "))) or ""
    local vars = {
        selection = clip(selection_text, MAX_SELECTION_CHARS),
        selection_chars = "",
        context = "", context_before = "", context_after = "", sentence = "",
        fragment_note = "",
        title = "", authors = "", series = "", language = "",
        chapter = "", page = "", pages = "", percent = "",
        date = "", time = "",
        provider = "", model = "",
    }
    vars.selection_chars = tostring(charCount(selection_text))

    local props = docProps(ui, doc)
    vars.title = clip(props.title, 100)
    vars.authors = clip(props.authors, 100)
    vars.series = clip(props.series, 100)
    vars.language = clip(props.language, 20)

    if ui and ui.toc and type(ui.toc.getTocTitleOfCurrentPage) == "function" then
        local ok, chapter = pcall(ui.toc.getTocTitleOfCurrentPage, ui.toc)
        if ok then
            vars.chapter = clip(chapter, 100)
        end
    end

    local page = callDoc(doc, "getCurrentPage")
    local pages = callDoc(doc, "getPageCount")
    if type(page) == "number" and page > 0 then
        vars.page = tostring(page)
    end
    if type(pages) == "number" and pages > 0 then
        vars.pages = tostring(pages)
        if type(page) == "number" and page > 0 then
            vars.percent = string.format("%d%%", math.floor(page / pages * 100 + 0.5))
        end
    end

    local now = os.date("*t")
    vars.date = string.format("%04d-%02d-%02d %s", now.year, now.month, now.day, weekdayName(now.wday))
    vars.time = string.format("%02d:%02d", now.hour, now.min)

    vars.provider = clip(type(provider) == "table" and provider.name or nil, 40)
    vars.model = clip(model, 60)

    local pos0 = type(selected_text) == "table" and selected_text.pos0 or nil
    local pos1 = type(selected_text) == "table" and selected_text.pos1 or nil
    -- 选区类型：插件只做"能确定的那部分判断"，模糊情形交给模型自己决定。
    local kind
    if not (doc and pos0 and pos1) then
        -- 手动输入或文件管理器查询：没有坐标，只剩字数可依据
        local n0 = charCount(vars.selection)
        if n0 <= 1 then
            kind = "single"
        elseif isLongSelection(vars.selection, n0) then
            kind = "long"
        else
            kind = "complete"
        end
    end
    if doc and pos0 and pos1 then
        -- 前后文走内置查询用过的同一入口；restore_selection=true 让 crengine 在
        -- 取完文字后重新记住选区，否则页面上的选中范围不再绘制。
        local prev_text, next_text = callDoc(doc, "getSelectedWordContext",
            vars.selection, CONTEXT_WORDS, pos0, pos1, true)
        vars.context_before = clip(prev_text, MAX_CONTEXT_CHARS)
        vars.context_after = clip(next_text, MAX_CONTEXT_CHARS)
        if vars.context_before ~= "" or vars.context_after ~= "" then
            vars.context = T(_("%1【%2】%3"), vars.context_before, vars.selection, vars.context_after)
        end

        -- 整句：内置翻译用它补全句末标点与语气，这里同样借力
        local extended = callDoc(doc, "extendXPointersToSentenceSegment", pos0, pos1)
        if type(extended) == "table" then
            vars.sentence = clip(extended.text, MAX_SENTENCE_CHARS)
        end

        -- 选区自检：看紧贴选区的左右各一个字符还是不是词内字符。
        -- 粘连 = 选区把词切开了，这是 e-ink 上最常见的偏差。
        local left_pos = callDoc(doc, "getPrevVisibleChar", pos0)
        local right_pos = callDoc(doc, "getNextVisibleChar", pos1)
        local glued_left = isWordChar(left_pos and textBetween(doc, left_pos, pos0) or "")
        local glued_right = isWordChar(right_pos and textBetween(doc, pos1, right_pos) or "")
        local n = charCount((type(selected_text) == "table" and selected_text.text) or vars.selection)
        if n <= 1 then
            -- 单字：绝大多数字能独立成词，剩下的要看搭配，交给模型按提示判断
            kind = "single"
        elseif isLongSelection(vars.selection, n) then
            -- 整句/长短语优先于"粘连"判断：模型看到一整句会自己挑一个词来解释
            kind = "long"
        elseif util.hasCJKChar(vars.selection) then
            -- 汉字之间本来就不加空格，两侧"粘连"是常态，不能据此断言选区不完整：
            -- 两字词（电话）和半个三字词（选中"计算"）从字符上看一模一样。
            kind = (glued_left and glued_right) and "maybe" or "complete"
        else
            -- 西文相反：两侧都贴着字母说明前后有空格，正好是整个单词；
            -- 只有一侧粘连才是被切开（选到 philoso，原文是 philosopher）。
            kind = (glued_left ~= glued_right) and "cut" or "complete"
        end

        -- 取粘连字符用的也是 getTextFromXPointers，它会把 crengine 的选区绘制抹掉，
        -- 这里补画一次，否则查询期间用户看不到自己选中的范围。
        callDoc(doc, "getTextFromXPointers", pos0, pos1, true)
    end

    vars.selection_kind = _(SELECTION_KIND_LABELS[kind] or "")
    -- 提示词模板末尾的 {{fragment_note}}：完整词条时是"别多写"的一句，
    -- 单字/切半/存疑时才给分层解释的指令。用户改模板时删掉这个占位符即可关闭。
    vars.fragment_note = AjbkSettings.SELECTION_HINTS[kind] or ""
    -- 没有原文就没有语境可依，得让模型知道：别猜语境、别标「（本句）」。
    -- 查词窗口按钮与主菜单手动查询都走这条路径。
    vars.lookup_note = (vars.sentence == "") and (AjbkSettings.LOOKUP_NOTE or "") or ""

    return vars
end

return AjbkContext
