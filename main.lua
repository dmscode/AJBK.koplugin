--[[--
AJBK（AI 百科）：把 AI 当字典、词典用。

在 KOReader 的查询体系中注册 AJBK 入口（与维基百科并存，不替换）：
  1. 查词窗口底部 AJBK 按钮（ReaderDictionary:addToDictButtons 官方 API）；
  2. 选中文字弹窗的 AJBK 项（ReaderHighlight:addToHighlightDialog 官方 API）；
  3. 主菜单 搜索 → AJBK 设置（sorting_hint = "search"）。

点击后携带提示词向 OpenAI 兼容的 AI 提供商发起一次性小请求（默认关闭思考、
max_tokens=512），结果经纯文本后处理后显示在原生查询窗口。
选中文字路径会额外带上前后文、所在整句、书籍元数据与章节进度
（见 ajbk_context.lua），以抵消电子墨水屏拖选不准的问题；
结果仍由原生 showDict 窗口渲染，因此翻页、选中、TTS 全部可用。

性能优先：widget 惰性加载、网络请求在可取消的 Trapper 子进程中执行、
插件自身不驻留大对象。详见 docs/需求文档.md 与 docs/技术调研.md。

@module koplugin.ajbk
--]]

local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local util = require("util")
local _ = require("gettext")
local T = require("ffi/util").template

local AjbkSettings = require("ajbk_settings")
local AjbkNet = require("ajbk_net")
local AjbkContext = require("ajbk_context")

-- 其余 widget（InputDialog/Menu/ConfirmBox/InfoMessage/TextViewer 等）
-- 均在使用处惰性加载，降低插件装载与驻留成本。

local AJBK = WidgetContainer:extend{
    name = "ajbk",
    is_doc_only = false,
}

--- util.trim 只认字符串，这里统一兜住 nil
local function trim(s)
    if type(s) ~= "string" then
        return ""
    end
    return util.trim(s)
end

--- 按字符截断（进度框里放不下整段选区）
local function ellipsize(text, max)
    local chars = util.splitToChars(text or "")
    if #chars <= max then
        return text or ""
    end
    return table.concat(chars, "", 1, max) .. "…"
end

function AJBK:showInfo(text, timeout)
    local InfoMessage = require("ui/widget/infomessage")
    UIManager:show(InfoMessage:new{
        text = text,
        timeout = timeout or 6,
    })
end

-- ----------------------------------------------------------------
-- 注册三个入口
-- ----------------------------------------------------------------

function AJBK:init()
    -- 配置放设置目录（插件目录会被升级/重装整体替换，放里面等于"升级即丢配置"）；
    -- 返回值交给 settings_file，插件管理器删插件时才会顺手清掉这份配置
    self.settings_file = AjbkSettings.init(self.path)

    if self.ui and self.ui.menu then
        self.ui.menu:registerToMainMenu(self)
    else
        -- 静默跳过会变成"主菜单里没有 AJBK"，而设备上没法调试；
        -- 留一条日志，crash.log 里能看出是加载时机问题还是别的
        logger.warn("AJBK: ui.menu 不可用，主菜单入口未注册")
    end
    -- 入口 1：查词窗口底部按钮（与 Wikipedia 同级，参与"自定义窗口按钮"管理）
    if self.ui and self.ui.dictionary then
        self.ui.dictionary:addToDictButtons({
            id = "ajbk",
            text = "AJBK",
            menu_text = _("AJBK"),
            callback = function(lookup)
                self:onDictButton(lookup)
            end,
        })
    end
    -- 入口 2：选中文字弹窗（排在 07_translate 之后）
    if self.ui and self.ui.highlight then
        self.ui.highlight:addToHighlightDialog("08_ajbk", function(highlight)
            return {
                text = _("AJBK"),
                enabled = highlight.selected_text ~= nil,
                callback = function()
                    self:onHighlightButton(highlight)
                end,
            }
        end)
    end
end

--- 查词窗口按钮：从 DictQuickLookup 实例取词。
--- 这条路径拿不到选区坐标，因此没有前后文（模板里对应整行会被删掉）。
function AJBK:onDictButton(lookup)
    local word
    if lookup.is_wiki then
        -- 维基结果窗口：展示中的词条即已清洗的页面标题
        word = lookup.lookupword or lookup.word
    else
        word = lookup.word
        local dictionary = lookup.ui and lookup.ui.dictionary
        if dictionary and dictionary.cleanSelection then
            -- DictQuickLookup 上没有 is_sane_word 这个字段（上游只读不写），
            -- 传 nil 会走"非 sane"的激进清洗，把 can't、l'amour 的撇号连同
            -- 所有格一起削掉。词典结果的词本身已是干净的词条，按 sane 处理。
            word = dictionary:cleanSelection(word, true)
        end
    end
    word = trim(word)
    if word == "" then
        self:showInfo(_("AJBK：未获取到有效文字。"), 3)
        return
    end
    self:queryWord(word, lookup.word_boxes, lookup.ui, nil, nil)
end

--- 选中文字弹窗：从 ReaderHighlight 实例取词。
--- 清洗走 dictionary:cleanSelection，与查词窗口路径保持一致：
--- e-ink 上误选带进来的引号、破折号、间隔号必须先去掉，否则会变成"词"的一部分。
function AJBK:onHighlightButton(highlight)
    local selected_text = highlight.selected_text
    if not selected_text or not selected_text.text then
        return
    end
    local word = selected_text.text
    local dictionary = highlight.ui and highlight.ui.dictionary
    if dictionary and dictionary.cleanSelection then
        word = dictionary:cleanSelection(word, false)
    else
        word = util.cleanupSelectedText(word)
    end
    word = trim(word)
    if word == "" then
        self:showInfo(_("AJBK：选中的内容没有可查询的文字。"), 3)
        return
    end
    self:queryWord(word, selected_text.sboxes, highlight.ui, highlight, selected_text)
end

-- ----------------------------------------------------------------
-- 查询编排
-- ----------------------------------------------------------------

--- 进度框 + 子进程 + 可取消，三件套统一在这里。
--- 注意：Trapper:wrap 会 coroutine.yield，回调的后半段是在子进程结束后才被
--- trapper 恢复执行的——所以结果只能通过 on_done 回调交出，不能靠返回值
--- （返回值在 resume 那一刻就已经返回给调用方了，那时 result 还是空的）。
--- on_done(ok, value)：ok=false 表示请求失败但流程正常，value 是错误文本；
--- 用户中途取消时 on_done 不会被调用。
function AJBK:runWithProgress(progress_text, task, on_done, show_delay)
    local Trapper = require("ui/trapper")
    local InfoMessage = require("ui/widget/infomessage")
    Trapper:wrap(function()
        local progress = InfoMessage:new{
            text = progress_text,
            show_delay = show_delay or 0.5,
        }
        UIManager:show(progress)
        local go_on, ok, value = Trapper:dismissableRunInSubprocess(task, progress)
        UIManager:close(progress)
        if go_on then
            on_done(ok, value)
        end
    end)
end

--- 核心：上下文 → 提示词 → AI 请求 → 原生窗口展示。
--- highlight：来自选中弹窗时传 ReaderHighlight 实例（关闭窗口时清除高亮），
--- 与词典查询行为一致；查词窗口按钮路径传 nil（与维基窗口一致）。
--- selected_text：ReaderHighlight.selected_text，带 pos0/pos1 才能取前后文。
function AJBK:queryWord(word, boxes, ui, highlight, selected_text)
    ui = ui or self.ui
    word = trim(word)
    if word == "" then
        return
    end

    local NetworkMgr = require("ui/network/manager")

    local provider = AjbkSettings.getActiveProvider()
    if not provider then
        self:showInfo(_("AJBK：尚未配置 AI 提供商。\n请到 菜单 → 搜索 → AJBK → 提供商与模型 中添加。"), 8)
        return
    end
    if provider.need_key ~= false and (provider.api_key == nil or provider.api_key == "") then
        self:showInfo(T(_("AJBK：请先为「%1」填写 API Key（AJBK → 提供商与模型）。"), provider.name), 8)
        return
    end
    local model = AjbkSettings.getEffectiveModel(provider)
    if not model or model == "" then
        self:showInfo(T(_("AJBK：请先为「%1」选择模型（AJBK → 提供商与模型 → 该提供商）。"), provider.name), 8)
        return
    end

    -- 离线时挂起，联网后自动重试（与维基百科查询一致）
    if NetworkMgr:willRerunWhenOnline(function()
        self:queryWord(word, boxes, ui, highlight, selected_text)
    end) then
        return
    end

    -- 上下文采集放在联网判断之后：离线重试时不必重复取一遍书里的文字
    local vars = AjbkContext.build(ui, word, selected_text, provider, model)
    -- 目标语言是用户设置而非"上下文"，在这里补进去
    vars.target_language = AjbkSettings.getTargetLanguage()
    local prompt_text = AjbkSettings.buildPrompt(vars)
    local thinking = AjbkSettings.getThinking()
    -- 不记录正文：crash.log 会留在设备上，书里选中的文字不该出现在那里
    logger.dbg("AJBK query:", provider.id, model, thinking, vars.selection_chars .. "字")

    self:runWithProgress(
        T(_("AJBK 查询中：\n%1\n（点按可取消）"), ellipsize(word, 24)),
        function()
            return AjbkNet.chatCompletion(provider, model, prompt_text, thinking)
        end,
        function(ok, content)
            if not ok then
                self:showInfo(T(_("AJBK 查询失败：\n%1"), content or _("（未知错误）")), 8)
                return
            end
            self:showResult(ui, word, content, boxes, highlight)
        end)
end

--- 结果展示：优先复用原生查询窗口；非阅读界面（文件管理器手动查询）用文本查看器
function AJBK:showResult(ui, word, content, boxes, highlight)
    local dictionary = ui and ui.dictionary
    if not dictionary or not dictionary.showDict then
        local TextViewer = require("ui/widget/textviewer")
        UIManager:show(TextViewer:new{
            title = T(_("AJBK：%1"), word),
            text = content,
        })
        return
    end
    local results = {
        {
            dict = "AJBK",
            word = word,
            definition = content,
        },
    }
    -- 词典模块只在"查词进行中"才持有 highlight，平时为 nil；
    -- 这里临时借位让 showDict 把高亮/跳转能力带给我们的结果窗口，用完还原
    local old_highlight = dictionary.highlight
    dictionary.highlight = highlight
    -- 用官方方法收掉可能还挂着的"查词中"提示，而不是直接把字段置 nil
    -- （置 nil 只会丢掉引用，提示框本身仍留在窗口栈里）
    if type(dictionary.dismissLookupInfo) == "function" then
        pcall(dictionary.dismissLookupInfo, dictionary)
    end
    dictionary:showDict(word, results, boxes)
    dictionary.highlight = old_highlight
end

-- ----------------------------------------------------------------
-- 主菜单：AJBK 设置
-- ----------------------------------------------------------------

--- 主菜单位置：搜索 tab（reader_menu_order 的 "search"，与 词典查询/维基百科查询
--- 同级，两层可达；文件管理器菜单的 search 区同样适用）
function AJBK:addToMainMenu(menu_items)
    -- 设备上没法调试，留一条 info 级日志（crash.log 必记）用于确认
    -- "主菜单入口到底注册上没有"
    logger.info("AJBK: addToMainMenu 被调用")
    menu_items.ajbk = {
        text = _("AJBK（AI 基百科）"),
        sorting_hint = "search",
        sub_item_table = {
            {
                text = _("查询词语"),
                callback = function()
                    self:showManualLookup()
                end,
            },
            {
                text_func = function()
                    local p = AjbkSettings.getActiveProvider()
                    return T(_("提供商与模型（当前：%1）"), p and p.name or _("未配置"))
                end,
                sub_item_table_func = function()
                    return self:genProviderManageMenu()
                end,
            },
            {
                text = _("思考模式"),
                sub_item_table_func = function()
                    return self:genThinkingMenu()
                end,
            },
            {
                text_func = function()
                    return T(_("目标语言（当前：%1）"), _(AjbkSettings.getTargetLanguageLabel()))
                end,
                sub_item_table_func = function()
                    return self:genTargetLanguageMenu()
                end,
            },
            {
                text = _("系统提示词"),
                sub_item_table_func = function()
                    return self:genPromptMenu()
                end,
            },
        },
    }
end

--- 提供商与模型（合并管理）：添加预设 / 添加自定义 / 每家提供商的
--- 模型选择、连接测试、编辑与删除
function AJBK:genProviderManageMenu()
    local providers = AjbkSettings.getProviders()
    local items = {}

    items[#items + 1] = {
        text = _("添加预设提供商"),
        -- 用 sub_item_table_func 而不是静态表：加完一家再回来，列表里
        -- 应该少掉那一项，静态表会一直显示全部预设
        sub_item_table_func = function()
            return self:genPresetMenu()
        end,
    }

    items[#items + 1] = {
        text = _("添加自定义提供商"),
        keep_menu_open = true,
        callback = function(touchmenu)
            self:showAddCustomProviderDialog(touchmenu)
        end,
    }

    for _, p in ipairs(providers) do
        items[#items + 1] = {
            -- 手改配置文件时可能缺 name，缺了就用 id 兜底：
            -- nil .. " ●" 会直接抛错，整个菜单打不开
            text = (p.name or p.id or "?") .. (AjbkSettings.getActiveId() == p.id and " ●" or ""),
            sub_item_table = self:genProviderEditMenu(p),
        }
    end
    return items
end

--- 未添加的预设列表。每次打开父菜单重建，加过的不再出现。
function AJBK:genPresetMenu()
    local providers = AjbkSettings.getProviders()
    local presets = require("ajbk_presets")
    local sub = {}
    for _, preset in ipairs(presets) do
        local exists = false
        for _, p in ipairs(providers) do
            if p.id == preset.id then
                exists = true
                break
            end
        end
        if not exists then
            sub[#sub + 1] = {
                text = preset.name,
                keep_menu_open = true,
                callback = function(touchmenu)
                    self:addPresetProvider(preset, touchmenu)
                end,
            }
        end
    end
    if #sub == 0 then
        sub[#sub + 1] = {
            text = _("（全部预设都已添加）"),
            enabled_func = function() return false end,
        }
    end
    return sub
end

function AJBK:genProviderEditMenu(p)
    return {
        {
            text_func = function()
                local m = AjbkSettings.getEffectiveModel(p)
                return T(_("当前模型：%1"), m or _("未选择"))
            end,
            enabled_func = function() return false end,
        },
        {
            text = _("测试连接并获取模型列表"),
            keep_menu_open = true,
            callback = function(touchmenu)
                self:fetchAndShowModels(p, touchmenu)
            end,
        },
        {
            text = _("手动输入模型名"),
            keep_menu_open = true,
            callback = function(touchmenu)
                self:showManualModelDialog(p, touchmenu)
            end,
        },
        {
            text = _("设为当前提供商"),
            enabled_func = function()
                return AjbkSettings.getActiveId() ~= p.id
            end,
            callback = function(touchmenu)
                AjbkSettings.setActiveId(p.id)
                if touchmenu then
                    touchmenu:updateItems()
                end
            end,
        },
        {
            text = _("修改 API Key"),
            keep_menu_open = true,
            enabled_func = function()
                return p.need_key ~= false
            end,
            callback = function()
                self:showApiKeyDialog(p)
            end,
        },
        {
            text = _("修改 API 地址"),
            keep_menu_open = true,
            callback = function()
                self:showBaseUrlDialog(p)
            end,
        },
        {
            -- 预设自带 thinking_style，自定义提供商没有——于是"思考模式"的档位
            -- 对它完全无效：智谱/GLM 这类默认就思考的模型会先把 max_tokens
            -- 烧在推理上，回来只有 reasoning_content，正文是空的
            text_func = function()
                local styles = AjbkSettings.THINKING_STYLES
                for _, s in ipairs(styles) do
                    if s.key == p.thinking_style then
                        return T(_("思考参数（当前：%1）"), _(s.label))
                    end
                end
                return T(_("思考参数（当前：%1）"), _("无（不发送）"))
            end,
            keep_menu_open = true,
            sub_item_table_func = function()
                local items = {}
                for _, s in ipairs(AjbkSettings.THINKING_STYLES) do
                    items[#items + 1] = {
                        text = _(s.label),
                        checked_func = function()
                            return (p.thinking_style or "") == (s.key or "")
                        end,
                        keep_menu_open = true,
                        callback = function(touchmenu)
                            AjbkSettings.updateProvider(p.id, { thinking_style = s.key })
                            if touchmenu then
                                touchmenu:updateItems()
                            end
                        end,
                    }
                end
                return items
            end,
        },
        {
            text = _("删除该提供商"),
            callback = function(touchmenu)
                local ConfirmBox = require("ui/widget/confirmbox")
                UIManager:show(ConfirmBox:new{
                    text = T(_("删除提供商「%1」及其 API Key？"), p.name),
                    ok_text = _("删除"),
                    ok_callback = function()
                        local removed, err = AjbkSettings.removeProvider(p.id)
                        if touchmenu then
                            touchmenu:updateItems()
                        end
                        if not removed then
                            self:showInfo(err == "unwritable"
                                and _("提供商已移除，但配置写入失败（设置目录不可写）。")
                                or _("该提供商已不存在。"), 6)
                        end
                    end,
                })
            end,
        },
    }
end

function AJBK:addPresetProvider(preset, touchmenu)
    local added, err = AjbkSettings.addProvider({
        id = preset.id,
        name = preset.name,
        base_url = preset.base_url,
        thinking_style = preset.thinking_style,
        need_key = preset.need_key,
        default_model = preset.default_model,
        is_preset = true,
        api_key = "",
    })
    if not added then
        if err == "unwritable" then
            self:showInfo(_("添加失败：配置写入失败（设置目录不可写）。"), 6)
        else
            self:showInfo(_("该提供商已在列表中。"), 3)
        end
        return
    end
    if touchmenu then
        touchmenu:updateItems()
    end
    -- 添加后立即引导填写 Key，减少来回跳转
    if preset.need_key ~= false then
        self:showApiKeyDialog(added)
    end
end

function AJBK:showApiKeyDialog(p)
    local InputDialog = require("ui/widget/inputdialog")
    local dialog
    dialog = InputDialog:new{
        title = T(_("「%1」API Key"), p.name),
        input = p.api_key or "",
        -- 掩码是 text_type；input_type 只控制数字键盘，写成 password 毫无效果
        text_type = "password",
        buttons = {
            {
                {
                    text = _("取消"),
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("测试"),
                    callback = function()
                        -- 用输入框中的值（未保存）测试
                        self:testConnection(p.base_url, dialog:getInputText())
                    end,
                },
                {
                    text = _("保存"),
                    is_enter_default = true,
                    callback = function()
                        local saved = AjbkSettings.updateProvider(p.id, { api_key = dialog:getInputText() })
                        UIManager:close(dialog)
                        if saved == false then
                            self:showInfo(_("API Key 已更新，但配置写入失败（设置目录不可写）。"), 6)
                        else
                            self:showInfo(_("API Key 已保存。"), 2)
                        end
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function AJBK:showBaseUrlDialog(p)
    local InputDialog = require("ui/widget/inputdialog")
    local dialog
    dialog = InputDialog:new{
        title = T(_("「%1」API 地址"), p.name),
        input = p.base_url or "",
        input_hint = "https://host/v1",
        description = _("OpenAI 兼容根地址，将拼接 /chat/completions 与 /models。本机服务请写全 http://。"),
        buttons = {
            {
                {
                    text = _("取消"),
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("测试"),
                    callback = function()
                        -- 用已保存的 Key + 输入框中的地址测试
                        self:testConnection(dialog:getInputText(), p.api_key)
                    end,
                },
                {
                    text = _("保存"),
                    is_enter_default = true,
                    callback = function()
                        local url, err = AjbkNet.normalizeBaseUrl(dialog:getInputText())
                        if not url then
                            self:showInfo(err, 5)
                            return
                        end
                        local saved = AjbkSettings.updateProvider(p.id, { base_url = url })
                        UIManager:close(dialog)
                        if saved == false then
                            self:showInfo(_("API 地址已更新，但配置写入失败（设置目录不可写）。"), 6)
                        else
                            self:showInfo(T(_("API 地址已保存：%1"), url), 3)
                        end
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

--- 自定义提供商 id：os.time() 生成，同一秒内连加两次会撞，
--- 这里往后探测到第一个没被占用的
local function nextCustomProviderId()
    local n = os.time()
    while AjbkSettings.getProvider("custom_" .. tostring(n)) do
        n = n + 1
    end
    return "custom_" .. tostring(n)
end

function AJBK:showAddCustomProviderDialog(touchmenu)
    local MultiInputDialog = require("ui/widget/multiinputdialog")
    local dialog
    dialog = MultiInputDialog:new{
        title = _("添加自定义提供商"),
        fields = {
            {
                text = "",
                description = _("名称："),
            },
            {
                text = "",
                description = _("API 地址（OpenAI 兼容，如 https://host/v1）："),
            },
            {
                text = "",
                description = _("API Key："),
                -- 掩码要 text_type，MultiInputDialog 会透传给内部 InputText
                text_type = "password",
            },
        },
        buttons = {
            {
                {
                    text = _("取消"),
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("测试"),
                    callback = function()
                        -- 用输入框中的地址与 Key（未保存）测试
                        local fields = dialog:getFields()
                        self:testConnection(fields[2] or "", fields[3] or "")
                    end,
                },
                {
                    text = _("保存"),
                    is_enter_default = true,
                    callback = function()
                        local fields = dialog:getFields()
                        local name = trim(fields[1])
                        local base_url, err = AjbkNet.normalizeBaseUrl(fields[2])
                        local api_key = fields[3] or ""
                        if name == "" then
                            self:showInfo(_("名称不能为空。"), 3)
                            return
                        end
                        if not base_url then
                            self:showInfo(err, 5)
                            return
                        end
                        local added, add_err = AjbkSettings.addProvider({
                            id = nextCustomProviderId(),
                            name = name,
                            base_url = base_url,
                            api_key = api_key,
                            need_key = true,
                            is_preset = false,
                        })
                        UIManager:close(dialog)
                        if not added then
                            self:showInfo(add_err == "unwritable"
                                and _("添加失败：配置写入失败（设置目录不可写）。")
                                or _("添加失败：提供商 id 冲突。"), 6)
                            return
                        end
                        if touchmenu then
                            touchmenu:updateItems()
                        end
                        self:showInfo(T(_("已添加「%1」。"), name), 2)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

--- 连接测试（各填写对话框的"测试"按钮共用）：
--- GET {base}/models 验证地址与 Key，成功时报告模型数量
function AJBK:testConnection(base_url, api_key)
    local url, err = AjbkNet.normalizeBaseUrl(base_url)
    if not url then
        self:showInfo(err, 5)
        return
    end
    local NetworkMgr = require("ui/network/manager")
    NetworkMgr:runWhenOnline(function()
        self:runWithProgress(_("正在测试连接…\n（点按可取消）"), function()
            return AjbkNet.fetchModels(url, api_key)
        end, function(ok, result)
            if ok then
                -- 子进程没有输出时 trapper 只回 completed，result 会是 nil：
                -- 直接拼 %1 会让用户看到字面的 %1
                local n = type(result) == "table" and #result or 0
                self:showInfo(T(_("连接成功，服务端返回 %1 个模型。\n地址与 API Key 有效。"), n), 5)
            else
                self:showInfo(T(_("测试失败：\n%1"), result or _("（未知错误）")), 8)
            end
        end, 0.3)
    end)
end

function AJBK:fetchAndShowModels(provider, touchmenu)
    if provider.need_key ~= false and (provider.api_key == nil or provider.api_key == "") then
        self:showInfo(_("请先填写该提供商的 API Key（可在填写时直接点「测试」验证）。"), 5)
        return
    end
    local NetworkMgr = require("ui/network/manager")
    NetworkMgr:runWhenOnline(function()
        self:runWithProgress(_("正在获取模型列表…\n（点按可取消）"), function()
            return AjbkNet.fetchModels(provider.base_url, provider.api_key)
        end, function(ok, result)
            if not ok then
                self:showInfo(T(_("获取模型列表失败：\n%1\n\n可改用「手动输入模型名」。"),
                    result or _("（未知错误）")), 8)
                return
            end
            local models = type(result) == "table" and result or {}
            if #models == 0 then
                self:showInfo(_("服务器未返回模型列表，可改用「手动输入模型名」。"), 5)
                return
            end
            self:showModelListDialog(provider, models, touchmenu)
        end, 0.3)
    end)
end

function AJBK:showModelListDialog(provider, models, touchmenu)
    local Menu = require("ui/widget/menu")
    local Screen = require("device").screen
    local current = AjbkSettings.getEffectiveModel(provider)
    local model_menu
    local item_table = {}
    for _, m in ipairs(models) do
        item_table[#item_table + 1] = {
            -- 标出当前生效的模型：列表动辄上百项，没有标记等于每次都要重新找
            text = (m == current and "● " or "") .. m,
            callback = function()
                AjbkSettings.setModel(provider.id, m)
                UIManager:close(model_menu)
                if touchmenu then
                    touchmenu:updateItems()
                end
                self:showInfo(T(_("已选择模型：%1"), m), 2)
            end,
        }
    end
    model_menu = Menu:new{
        title = T(_("选择模型 — %1"), provider.name),
        item_table = item_table,
        width = Screen:getWidth(),
        height = Screen:getHeight(),
    }
    UIManager:show(model_menu)
end

function AJBK:showManualModelDialog(provider, touchmenu)
    local InputDialog = require("ui/widget/inputdialog")
    local dialog
    dialog = InputDialog:new{
        title = T(_("「%1」模型名"), provider.name),
        input = AjbkSettings.getEffectiveModel(provider) or "",
        input_hint = "deepseek-chat",
        buttons = {
            {
                {
                    text = _("取消"),
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("保存"),
                    is_enter_default = true,
                    callback = function()
                        local model = trim(dialog:getInputText())
                        if model == "" then
                            return
                        end
                        AjbkSettings.setModel(provider.id, model)
                        UIManager:close(dialog)
                        -- 父菜单是 keep_menu_open 打开的，不刷新就会一直显示旧模型名
                        if touchmenu then
                            touchmenu:updateItems()
                        end
                        self:showInfo(T(_("模型已设为：%1"), model), 2)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

--- 思考模式：off / low / medium / high（映射方式见 ajbk_net.lua）
--- 只有四种已映射的参数风格才允许点选：没有映射时点选不发任何参数，
--- 用户会以为"设置了却没生效"，不如直接灰掉并说明原因
function AJBK:genThinkingMenu()
    local provider = AjbkSettings.getActiveProvider()
    local style_hint
    local hints = {
        thinking_type = _("通过 thinking.type 参数控制"),
        enable_thinking = _("通过 enable_thinking 参数控制"),
        reasoning_effort = _("通过 reasoning_effort 参数控制（部分推理模型无法完全关闭）"),
        openrouter_reasoning = _("通过 reasoning 参数控制"),
        model_choice = _("该提供商通过选择模型控制思考（如 deepseek-chat / deepseek-reasoner）"),
    }
    if not provider then
        style_hint = _("未配置提供商")
    else
        style_hint = hints[provider.thinking_style]
            or _("未映射该提供商的思考参数；思考内容一律剥离，不显示。")
    end
    local style = provider and provider.thinking_style
    local mapped = style == "thinking_type" or style == "enable_thinking"
        or style == "reasoning_effort" or style == "openrouter_reasoning"

    local items = {
        {
            text = T(_("当前提供商：%1"), provider and provider.name or _("未配置")),
            enabled_func = function() return false end,
        },
        {
            text = _("参数映射：") .. style_hint,
            enabled_func = function() return false end,
        },
    }
    local levels = {
        { id = "off", text = _("关闭（推荐，响应最快）") },
        { id = "low", text = _("低") },
        { id = "medium", text = _("中") },
        { id = "high", text = _("高") },
    }
    for _, lvl in ipairs(levels) do
        items[#items + 1] = {
            text = lvl.text,
            radio = true,
            enabled_func = function() return mapped end,
            checked_func = function()
                return AjbkSettings.getThinking() == lvl.id
            end,
            callback = function()
                AjbkSettings.setThinking(lvl.id)
            end,
        }
    end
    return items
end

--- 目标语言：释义用哪种语言回答。跟"阅读原文语言"解耦——
--- 读英文书也想看中文解释时，改这里就够了
function AJBK:genTargetLanguageMenu()
    local items = {}
    -- 循环变量不能叫 _：那会把模块顶部 local _ = require("gettext") 遮住，
    -- 循环体里 _("...") 就变成"调用一个数字"，设备上直接崩出 reader.lua
    for index, lang in ipairs(AjbkSettings.TARGET_LANGUAGES) do
        items[#items + 1] = {
            text = _(lang.label),
            radio = true,
            checked_func = function()
                return AjbkSettings.getTargetLanguage() == lang.value
            end,
            callback = function()
                local saved = AjbkSettings.setTargetLanguage(lang.value)
                if saved == false then
                    self:showInfo(_("目标语言已改，但配置写入失败（设置目录不可写）。"), 6)
                end
            end,
        }
    end
    items[#items + 1] = {
        -- 自定义项：语言名是自然语言，模型自己就懂，不必枚举一长串
        text_func = function()
            local current = AjbkSettings.getTargetLanguage()
            if AjbkSettings.isPresetLanguage(current) then
                return _("自定义…")
            end
            return T(_("自定义…（当前：%1）"), current)
        end,
        radio = true,
        checked_func = function()
            return not AjbkSettings.isPresetLanguage(AjbkSettings.getTargetLanguage())
        end,
        callback = function(touchmenu)
            self:showTargetLanguageDialog(touchmenu)
        end,
    }
    items[#items + 1] = {
        text = _("提示：这只影响释义语言，读音与词性照常按原文处理。"),
        enabled_func = function() return false end,
    }
    return items
end

--- 自定义目标语言：直接写"日文""繁體中文"都行，AI 能懂
function AJBK:showTargetLanguageDialog(touchmenu)
    local InputDialog = require("ui/widget/inputdialog")
    local UIManager = require("ui/uimanager")
    local current = AjbkSettings.getTargetLanguage()
    local dialog
    dialog = InputDialog:new{
        title = _("目标语言"),
        description = _("填语言名即可，例如：日文、繁體中文、English。\n留空则恢复默认（中文）。"),
        input = AjbkSettings.isPresetLanguage(current) and "" or current,
        input_hint = _("例如：日文"),
        buttons = {
            {
                {
                    text = _("取消"),
                    id = "cancel",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("保存"),
                    id = "save",
                    callback = function()
                        local text = trim(dialog:getInputText())
                        local saved = AjbkSettings.setTargetLanguage(text == "" and "中文" or text)
                        UIManager:close(dialog)
                        if touchmenu then
                            touchmenu:updateItems()
                        end
                        if saved == false then
                            self:showInfo(_("目标语言已改，但配置写入失败（设置目录不可写）。"), 6)
                        end
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

--- 系统提示词：编辑 / 插入占位符 / 恢复默认
function AJBK:genPromptMenu()
    return {
        {
            text_func = function()
                return AjbkSettings.isPromptCustom()
                    and _("当前：自定义提示词")
                    or _("当前：默认提示词")
            end,
            enabled_func = function() return false end,
        },
        {
            text = _("编辑提示词"),
            keep_menu_open = true,
            callback = function(touchmenu)
                self:showPromptDialog(nil, touchmenu)
            end,
        },
        {
            text = _("插入占位符"),
            keep_menu_open = true,
            sub_item_table_func = function()
                return self:genPlaceholderMenu()
            end,
        },
        {
            text = _("恢复默认提示词"),
            keep_menu_open = true,
            enabled_func = function()
                return AjbkSettings.isPromptCustom()
            end,
            callback = function(touchmenu)
                local ConfirmBox = require("ui/widget/confirmbox")
                UIManager:show(ConfirmBox:new{
                    text = _("恢复默认提示词？"),
                    ok_text = _("恢复"),
                    ok_callback = function()
                        AjbkSettings.resetPrompt()
                        if touchmenu then
                            touchmenu:updateItems()
                        end
                    end,
                })
            end,
        },
    }
end

--- 占位符清单：点一项就把 {{key}} 追加到提示词末尾并打开编辑器
function AJBK:genPlaceholderMenu()
    local items = {
        {
            text = _("占位符没有值时，它所在的那一行会被整行删掉。"),
            enabled_func = function() return false end,
        },
        {
            text = _("点选后会把占位符追加到末尾，可再自行挪动位置。"),
            enabled_func = function() return false end,
        },
    }
    -- 同上：循环变量别用 _，会遮住 gettext
    for index, ph in ipairs(AjbkSettings.PLACEHOLDERS) do
        items[#items + 1] = {
            text = "{{" .. ph.key .. "}}  " .. _(ph.label),
            keep_menu_open = true,
            callback = function(touchmenu)
                -- 追加后直接进编辑器；保存时用同一个 touchmenu 刷新父菜单
                self:showPromptDialog("{{" .. ph.key .. "}}", touchmenu)
            end,
        }
    end
    return items
end

function AJBK:showPromptDialog(append_placeholder, touchmenu)
    local InputDialog = require("ui/widget/inputdialog")
    local Screen = require("device").screen
    local text = AjbkSettings.getPrompt()
    if append_placeholder then
        text = text .. "\n" .. append_placeholder
    end
    local dialog
    dialog = InputDialog:new{
        title = _("编辑 AJBK 提示词"),
        description = _("可用占位符见「插入占位符」，如 {{selection}}、{{context}}、{{sentence}}、{{title}}、{{chapter}}、{{date}}。"),
        input = text,
        allow_newline = true,
        text_height = math.floor(Screen:getHeight() * 0.3),
        buttons = {
            {
                {
                    text = _("取消"),
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("保存"),
                    is_enter_default = true,
                    callback = function()
                        local new_text = dialog:getInputText()
                        if trim(new_text) == "" then
                            return
                        end
                        local saved
                        if new_text == AjbkSettings.DEFAULT_PROMPT then
                            saved = AjbkSettings.resetPrompt()
                        else
                            saved = AjbkSettings.setPrompt(new_text)
                        end
                        UIManager:close(dialog)
                        if touchmenu then
                            touchmenu:updateItems()
                        end
                        if saved == false then
                            self:showInfo(_("提示词已更新，但配置写入失败（设置目录不可写）。"), 6)
                        else
                            self:showInfo(_("提示词已保存。"), 2)
                        end
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

--- 手动输入词语查询（不依赖选中文本；阅读器与文件管理器菜单均可用）
function AJBK:showManualLookup()
    local InputDialog = require("ui/widget/inputdialog")
    local dialog
    dialog = InputDialog:new{
        title = _("AJBK 查询"),
        input = "",
        input_hint = _("输入生僻字、词语或短语"),
        buttons = {
            {
                {
                    text = _("取消"),
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("查询"),
                    is_enter_default = true,
                    callback = function()
                        local word = trim(dialog:getInputText())
                        if word == "" then
                            return
                        end
                        UIManager:close(dialog)
                        self:queryWord(word, nil, nil, nil, nil)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

return AJBK
