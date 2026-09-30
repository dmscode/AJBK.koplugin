--[[--
AJBK（AI 百科）：把 AI 当字典、词典用。

在 KOReader 的查询体系中注册 AJBK 入口（与维基百科并存，不替换）：
  1. 查词窗口底部 AJBK 按钮（ReaderDictionary:addToDictButtons 官方 API）；
  2. 选中文字弹窗的 AJBK 项（ReaderHighlight:addToHighlightDialog 官方 API）；
  3. 主菜单 工具 → 更多工具 → AJBK 设置。

点击后携带提示词向 OpenAI 兼容的 AI 提供商发起一次性小请求（默认关闭思考、
不带上下文、max_tokens≈300），结果经纯文本后处理后显示在原生查询窗口。
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

-- 其余 widget（InputDialog/Menu/ConfirmBox/InfoMessage/TextViewer 等）
-- 均在使用处惰性加载，降低插件装载与驻留成本。

local AJBK = WidgetContainer:extend{
    name = "ajbk",
    is_doc_only = false,
}

local function trim(s)
    if type(s) ~= "string" then
        return ""
    end
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
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
    -- 配置文件在插件目录内（self.path 由 PluginLoader 注入）；
    -- 声明 settings_file 让插件管理器支持"禁用并删除设置"
    if self.path then
        AjbkSettings.setConfigPath(self.path .. "/" .. AjbkSettings.CONFIG_FILENAME)
    end
    self.settings_file = AjbkSettings.getConfigPath()

    if self.ui and self.ui.menu then
        self.ui.menu:registerToMainMenu(self)
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

--- 查词窗口按钮：从 DictQuickLookup 实例取词
function AJBK:onDictButton(lookup)
    local word, is_sane
    if lookup.is_wiki then
        -- 维基结果窗口：展示中的词条即已清洗的页面标题
        word = lookup.lookupword or lookup.word
        is_sane = true
    else
        word = lookup.word
        is_sane = lookup.is_sane_word
        local dictionary = lookup.ui and lookup.ui.dictionary
        if dictionary and dictionary.cleanSelection then
            word = dictionary:cleanSelection(word, is_sane)
        end
    end
    word = trim(word or "")
    if word == "" then
        self:showInfo(_("AJBK：未获取到有效文字。"), 3)
        return
    end
    self:queryWord(word, lookup.word_boxes, lookup.ui, nil)
end

--- 选中文字弹窗：从 ReaderHighlight 实例取词
function AJBK:onHighlightButton(highlight)
    local selected_text = highlight.selected_text
    if not selected_text or not selected_text.text then
        return
    end
    local word = trim(util.cleanupSelectedText(selected_text.text))
    if word == "" then
        return
    end
    self:queryWord(word, selected_text.sboxes, highlight.ui, highlight)
end

-- ----------------------------------------------------------------
-- 查询编排
-- ----------------------------------------------------------------

--- 核心：提示词 → AI 请求 → 原生窗口展示。
--- highlight：来自选中弹窗时传 ReaderHighlight 实例（关闭窗口时清除高亮），
--- 与词典查询行为一致；查词窗口按钮路径传 nil（与维基窗口一致）。
function AJBK:queryWord(word, boxes, ui, highlight)
    ui = ui or self.ui
    word = trim(word or "")
    if word == "" then
        return
    end

    local NetworkMgr = require("ui/network/manager")

    local provider = AjbkSettings.getActiveProvider()
    if not provider then
        self:showInfo(_("AJBK：尚未配置 AI 提供商。\n请到 菜单 → 工具 → 更多工具 → AJBK → 提供商管理 中添加。"), 8)
        return
    end
    if provider.need_key ~= false and (provider.api_key == nil or provider.api_key == "") then
        self:showInfo(T(_("AJBK：请先为「%1」填写 API Key（AJBK → 提供商管理）。"), provider.name), 8)
        return
    end
    local model = AjbkSettings.getEffectiveModel(provider)
    if not model or model == "" then
        self:showInfo(T(_("AJBK：请先为「%1」选择模型（AJBK → 模型）。"), provider.name), 8)
        return
    end

    -- 离线时挂起，联网后自动重试（与维基百科查询一致）
    if NetworkMgr:willRerunWhenOnline(function()
        self:queryWord(word, boxes, ui, highlight)
    end) then
        return
    end

    local prompt_text = AjbkSettings.buildPrompt(word)
    local thinking = AjbkSettings.getThinking()
    logger.dbg("AJBK query:", provider.id, model, thinking, word)

    local Trapper = require("ui/trapper")
    Trapper:wrap(function()
        local InfoMessage = require("ui/widget/infomessage")
        local progress = InfoMessage:new{
            text = T(_("AJBK 查询中：\n%1\n（点按可取消）"), word),
            show_delay = 0.5,
        }
        UIManager:show(progress)
        -- 请求在子进程中执行：UI 保持响应，点按进度框即终止请求
        local go_on, ok, content = Trapper:dismissableRunInSubprocess(function()
            return AjbkNet.chatCompletion(provider, model, prompt_text, thinking)
        end, progress)
        UIManager:close(progress)
        if not go_on then
            return -- 用户取消
        end
        if not ok then
            self:showInfo(T(_("AJBK 查询失败：\n%1"), content), 8)
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
    -- 临时借用 dictionary.highlight 与 lookup_progress_msg 字段，
    -- 用完即还原，不改变词典模块自身状态
    local old_highlight = dictionary.highlight
    dictionary.highlight = highlight
    dictionary.lookup_progress_msg = nil
    dictionary:showDict(word, results, boxes)
    dictionary.highlight = old_highlight
end

-- ----------------------------------------------------------------
-- 主菜单：AJBK 设置
-- ----------------------------------------------------------------

--- 主菜单位置：搜索 tab（reader_menu_order 的 "search"，与 词典查询/维基百科查询
--- 同级，两层可达；文件管理器菜单的 search 区同样适用）
function AJBK:addToMainMenu(menu_items)
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

    local presets = require("presets")
    local not_added = {}
    for _, preset in ipairs(presets) do
        local exists = false
        for _, p in ipairs(providers) do
            if p.id == preset.id then
                exists = true
                break
            end
        end
        if not exists then
            not_added[#not_added + 1] = preset
        end
    end
    if #not_added > 0 then
        local sub = {}
        for _, preset in ipairs(not_added) do
            sub[#sub + 1] = {
                text = preset.name,
                keep_menu_open = true,
                callback = function(touchmenu)
                    self:addPresetProvider(preset, touchmenu)
                end,
            }
        end
        items[#items + 1] = {
            text = _("添加预设提供商"),
            sub_item_table = sub,
        }
    end

    items[#items + 1] = {
        text = _("添加自定义提供商"),
        keep_menu_open = true,
        callback = function()
            self:showAddCustomProviderDialog()
        end,
    }

    for _, p in ipairs(providers) do
        items[#items + 1] = {
            text = p.name .. (AjbkSettings.getActiveId() == p.id and " ●" or ""),
            sub_item_table = self:genProviderEditMenu(p),
        }
    end
    return items
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
            callback = function()
                self:fetchAndShowModels(p)
            end,
        },
        {
            text = _("手动输入模型名"),
            keep_menu_open = true,
            callback = function()
                self:showManualModelDialog(p)
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
            text = _("删除该提供商"),
            callback = function(touchmenu)
                local ConfirmBox = require("ui/widget/confirmbox")
                UIManager:show(ConfirmBox:new{
                    text = T(_("删除提供商「%1」及其 API Key？"), p.name),
                    ok_text = _("删除"),
                    ok_callback = function()
                        AjbkSettings.removeProvider(p.id)
                        if touchmenu then
                            touchmenu:updateItems()
                        end
                    end,
                })
            end,
        },
    }
end

function AJBK:addPresetProvider(preset, touchmenu)
    local ok = AjbkSettings.addProvider({
        id = preset.id,
        name = preset.name,
        base_url = preset.base_url,
        thinking_style = preset.thinking_style,
        need_key = preset.need_key,
        default_model = preset.default_model,
        is_preset = true,
        api_key = "",
    })
    if not ok then
        self:showInfo(_("该提供商已在列表中。"), 3)
        return
    end
    if touchmenu then
        touchmenu:updateItems()
    end
    -- 添加后立即引导填写 Key，减少来回跳转
    if preset.need_key ~= false then
        self:showApiKeyDialog(AjbkSettings.getProvider(preset.id))
    end
end

function AJBK:showApiKeyDialog(p)
    local InputDialog = require("ui/widget/inputdialog")
    local dialog
    dialog = InputDialog:new{
        title = T(_("「%1」API Key"), p.name),
        input = p.api_key or "",
        input_type = "password",
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
                        AjbkSettings.updateProvider(p.id, { api_key = dialog:getInputText() })
                        UIManager:close(dialog)
                        self:showInfo(_("API Key 已保存。"), 2)
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
        description = _("OpenAI 兼容根地址，将拼接 /chat/completions 与 /models。"),
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
                        self:testConnection(trim(dialog:getInputText()), p.api_key)
                    end,
                },
                {
                    text = _("保存"),
                    is_enter_default = true,
                    callback = function()
                        local url = trim(dialog:getInputText())
                        if url == "" then
                            return
                        end
                        AjbkSettings.updateProvider(p.id, { base_url = url })
                        UIManager:close(dialog)
                        self:showInfo(_("API 地址已保存。"), 2)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function AJBK:showAddCustomProviderDialog()
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
                input_type = "password",
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
                        self:testConnection(trim(fields[2]), fields[3] or "")
                    end,
                },
                {
                    text = _("保存"),
                    is_enter_default = true,
                    callback = function()
                        local fields = dialog:getFields()
                        local name = trim(fields[1])
                        local base_url = trim(fields[2])
                        local api_key = fields[3] or ""
                        if name == "" or base_url == "" then
                            self:showInfo(_("名称与 API 地址不能为空。"), 3)
                            return
                        end
                        local id = "custom_" .. tostring(os.time())
                        AjbkSettings.addProvider({
                            id = id,
                            name = name,
                            base_url = base_url,
                            api_key = api_key,
                            need_key = true,
                            is_preset = false,
                        })
                        UIManager:close(dialog)
                        self:showInfo(T(_("已添加「%1」。"), name), 2)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

--- 连接测试（填写对话框中的"测试"按钮共用）：
--- GET {base}/models 验证地址与 Key，成功时报告模型数量
function AJBK:testConnection(base_url, api_key)
    local NetworkMgr = require("ui/network/manager")
    NetworkMgr:runWhenOnline(function()
        local Trapper = require("ui/trapper")
        Trapper:wrap(function()
            local InfoMessage = require("ui/widget/infomessage")
            local progress = InfoMessage:new{
                text = _("正在测试连接…\n（点按可取消）"),
                show_delay = 0.3,
            }
            UIManager:show(progress)
            local go_on, ok, result = Trapper:dismissableRunInSubprocess(function()
                return AjbkNet.fetchModels(base_url, api_key)
            end, progress)
            UIManager:close(progress)
            if not go_on then
                return
            end
            if ok then
                self:showInfo(T(_("连接成功，服务端返回 %1 个模型。\n地址与 API Key 有效。"), #result), 5)
            else
                self:showInfo(T(_("测试失败：\n%1"), result), 8)
            end
        end)
    end)
end

function AJBK:fetchAndShowModels(provider)
    if provider.need_key ~= false and (provider.api_key == nil or provider.api_key == "") then
        self:showInfo(_("请先填写该提供商的 API Key（可在填写时直接点「测试」验证）。"), 5)
        return
    end
    local NetworkMgr = require("ui/network/manager")
    NetworkMgr:runWhenOnline(function()
        local Trapper = require("ui/trapper")
        Trapper:wrap(function()
            local InfoMessage = require("ui/widget/infomessage")
            local progress = InfoMessage:new{
                text = _("正在获取模型列表…\n（点按可取消）"),
                show_delay = 0.3,
            }
            UIManager:show(progress)
            local go_on, ok, models_or_err = Trapper:dismissableRunInSubprocess(function()
                return AjbkNet.fetchModels(provider.base_url, provider.api_key)
            end, progress)
            UIManager:close(progress)
            if not go_on then
                return
            end
            if not ok then
                self:showInfo(T(_("获取模型列表失败：\n%1\n\n可改用「手动输入模型名」。"), models_or_err), 8)
                return
            end
            if #models_or_err == 0 then
                self:showInfo(_("服务器未返回模型列表，可改用「手动输入模型名」。"), 5)
                return
            end
            self:showModelListDialog(provider, models_or_err)
        end)
    end)
end

function AJBK:showModelListDialog(provider, models)
    local Menu = require("ui/widget/menu")
    local Screen = require("device").screen
    local model_menu
    local item_table = {}
    for _, m in ipairs(models) do
        item_table[#item_table + 1] = {
            text = m,
            callback = function()
                AjbkSettings.setModel(provider.id, m)
                UIManager:close(model_menu)
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

function AJBK:showManualModelDialog(provider)
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
function AJBK:genThinkingMenu()
    local provider = AjbkSettings.getActiveProvider()
    local style_hint
    if not provider then
        style_hint = _("未配置提供商")
    else
        local hints = {
            thinking_type = _("通过 thinking.type 参数控制"),
            enable_thinking = _("通过 enable_thinking 参数控制"),
            reasoning_effort = _("通过 reasoning_effort 参数控制（部分推理模型无法完全关闭）"),
            openrouter_reasoning = _("通过 reasoning 参数控制"),
            model_choice = _("该提供商通过选择模型控制思考（如 deepseek-chat / deepseek-reasoner）"),
        }
        style_hint = hints[provider.thinking_style]
            or _("未映射该提供商的思考参数；思考内容一律剥离，不显示。")
    end

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

--- 系统提示词：编辑 / 恢复默认
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
            callback = function()
                self:showPromptDialog()
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

function AJBK:showPromptDialog()
    local InputDialog = require("ui/widget/inputdialog")
    local Screen = require("device").screen
    local dialog
    dialog = InputDialog:new{
        title = _("编辑 AJBK 提示词"),
        description = _("查询词将追加在提示词末尾发送；模板中可用 {{word}} 指定查询词位置。"),
        input = AjbkSettings.getPrompt(),
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
                        local text = dialog:getInputText()
                        if trim(text) == "" then
                            return
                        end
                        if text == AjbkSettings.DEFAULT_PROMPT then
                            AjbkSettings.resetPrompt()
                        else
                            AjbkSettings.setPrompt(text)
                        end
                        UIManager:close(dialog)
                        self:showInfo(_("提示词已保存。"), 2)
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
                        self:queryWord(word, nil, nil, nil)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

return AJBK
