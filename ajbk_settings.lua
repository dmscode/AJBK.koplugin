--[[--
AJBK 设置读写。

配置存储在**插件目录内的独立文件** ajbk_config.lua（KOReader LuaSettings 格式，
可手工编辑）：删除整个插件目录即无任何残留。使用的键：
  providers  已配置提供商表（数组，含 api_key）
  active     当前生效提供商 id
  models     各提供商选中模型（id → 模型名 映射表）
  prompt     自定义提示词（不存在即用默认）
  thinking   思考模式：off | low | medium | high
--]]

local AjbkSettings = {
    DEFAULT_PROMPT = "你忠实的扮演字典、词典的角色，不要任何废话，像字典一样去写出文字的读音，简单的释义即可。无需展开。现在用户向你查询的内容如下：",
    CONFIG_FILENAME = "ajbk_config.lua",
}

local config_path = nil -- 显式指定（main.lua 注入插件目录，或测试注入临时路径）
local instance = nil    -- LuaSettings 实例，惰性创建

--- 显式指定配置文件完整路径；须在首次访问设置前调用
function AjbkSettings.setConfigPath(path)
    config_path = path
    instance = nil
end

--- 配置文件所在位置：优先用显式注入值；否则根据本文件自身位置自定位
--- （本文件就在插件目录内）；再失败则退回 KOReader 设置目录
function AjbkSettings.getConfigPath()
    if not config_path then
        local source = debug.getinfo(1, "S").source
        if source:sub(1, 1) == "@" then
            local dir = source:sub(2):match("^(.*)[/\\][%w_%.-]+$")
            if dir and dir ~= "" then
                config_path = dir .. "/" .. AjbkSettings.CONFIG_FILENAME
            end
        end
        if not config_path then
            local DataStorage = require("datastorage")
            config_path = DataStorage:getSettingsDir() .. "/" .. AjbkSettings.CONFIG_FILENAME
        end
    end
    return config_path
end

local function S()
    if not instance then
        local LuaSettings = require("luasettings")
        instance = LuaSettings:open(AjbkSettings.getConfigPath())
    end
    return instance
end

local function save()
    S():flush()
end

--- 提供商 ----------------------------------------------------------

--- 返回已配置提供商数组（设置中的引用；改动后请调用 saveProviders）
function AjbkSettings.getProviders()
    return S():readSetting("providers", {})
end

function AjbkSettings.saveProviders(providers)
    S():saveSetting("providers", providers)
    save()
end

function AjbkSettings.getProvider(id)
    for _, p in ipairs(AjbkSettings.getProviders()) do
        if p.id == id then
            return p
        end
    end
end

--- 添加提供商；第一个自动设为当前。返回是否成功（id 重复则失败）。
function AjbkSettings.addProvider(provider)
    local providers = AjbkSettings.getProviders()
    for _, p in ipairs(providers) do
        if p.id == provider.id then
            return false
        end
    end
    providers[#providers + 1] = provider
    AjbkSettings.saveProviders(providers)
    if #providers == 1 then
        AjbkSettings.setActiveId(provider.id)
    end
    return true
end

function AjbkSettings.updateProvider(id, patch)
    local p = AjbkSettings.getProvider(id)
    if not p then
        return false
    end
    for k, v in pairs(patch) do
        p[k] = v
    end
    AjbkSettings.saveProviders(AjbkSettings.getProviders())
    return true
end

function AjbkSettings.removeProvider(id)
    local providers = AjbkSettings.getProviders()
    for i, p in ipairs(providers) do
        if p.id == id then
            table.remove(providers, i)
            AjbkSettings.saveProviders(providers)
            if AjbkSettings.getActiveId() == id then
                S():delSetting("active")
            end
            local models = AjbkSettings.getModels()
            models[id] = nil
            S():saveSetting("models", models)
            save()
            return true
        end
    end
    return false
end

--- 当前提供商 ------------------------------------------------------

function AjbkSettings.getActiveId()
    return S():readSetting("active")
end

function AjbkSettings.setActiveId(id)
    S():saveSetting("active", id)
    save()
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
    save()
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
    save()
end

function AjbkSettings.resetPrompt()
    S():delSetting("prompt")
    save()
end

--- 把查询词合入提示词：模板含 {{word}} 占位符则原位替换，
--- 否则追加在提示词末尾（默认提示词以"如下："收尾，正好衔接）。
function AjbkSettings.buildPrompt(word)
    local prompt = AjbkSettings.getPrompt()
    if prompt:find("{{word}}", 1, true) then
        return (prompt:gsub("{{word}}", function() return word end))
    end
    return prompt .. "\n" .. word
end

--- 思考模式 --------------------------------------------------------

function AjbkSettings.getThinking()
    return S():readSetting("thinking", "off")
end

function AjbkSettings.setThinking(level)
    S():saveSetting("thinking", level)
    save()
end

return AjbkSettings
