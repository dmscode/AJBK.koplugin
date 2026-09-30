# -*- coding: utf-8 -*-
"""AJBK.koplugin 桌面端验证：语法检查 + 纯函数单元测试（需 pip install lupa）。

用法：python tests/ajbk_test.py
路径无关（本地与 CI 均可运行）；不依赖 KOReader——
网络/socket 模块已惰性加载，纯函数层直接可测。
"""
import os
import sys
import io
import tempfile

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace")
from lupa import LuaRuntime

# 本脚本位于 <插件根>/tests/ 下，插件根即上一级目录
BASE = os.path.dirname(os.path.dirname(os.path.abspath(__file__))).replace("\\", "/")
TMP = tempfile.gettempdir().replace("\\", "/")

lua = LuaRuntime()

# ---- 1. 语法检查（等价 luac -p）----
files = ["_meta.lua", "presets.lua", "ajbk_settings.lua", "ajbk_net.lua", "main.lua"]
for f in files:
    r = lua.execute(f'''
        local f, err = loadfile([[{BASE}/{f}]])
        if f then return "OK" else return "FAIL: " .. tostring(err) end
    ''')
    print(f"SYNTAX {f}: {r}")
    if r != "OK":
        sys.exit(1)

# ---- 2. 可执行模块的单元测试 ----
lua.execute(r'''
package.preload["ffi/util"] = function()
    return { template = function(s, ...)
        local args = {...}
        local out = tostring(s)
        for i, v in ipairs(args) do
            out = out:gsub("%" .. i, tostring(v))
        end
        return out
    end }
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
    return { getSettingsDir = function() return "/tmp" end }
end

results = {}
local function check(name, ok, detail)
    results[#results + 1] = (ok and "PASS " or "FAIL ") .. name .. (detail and (" | " .. tostring(detail)) or "")
end

-- presets.lua
local presets = dofile([[@@BASE@@/presets.lua]])
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

-- ajbk_settings.lua
local S = dofile([[@@BASE@@/ajbk_settings.lua]])
S.setConfigPath([[@@TMP@@/ajbk_config_test.lua]])
check("配置路径注入", S.getConfigPath():find("ajbk_config_test%.lua", 1, false) ~= nil)
check("默认提示词原文", S.DEFAULT_PROMPT:find("现在用户向你查询的内容如下：", 1, true) ~= nil)

local ok1 = S.addProvider({ id = "a1", name = "甲", base_url = "https://x/v1", api_key = "", default_model = "m1" })
local ok_dup = S.addProvider({ id = "a1", name = "重复", base_url = "https://x/v1" })
check("addProvider 成功", ok1 == true)
check("addProvider 去重", ok_dup == false)
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
check("removeProvider 清理激活", S.getActiveId() == nil)
S.setActiveId("a1")

-- buildPrompt：追加与占位符
local p1 = S.buildPrompt("饕餮")
check("buildPrompt 追加", p1 == S.DEFAULT_PROMPT .. "\n饕餮")
S.setPrompt("查询{{word}}并解释。")
check("buildPrompt 占位符", S.buildPrompt("饕餮") == "查询饕餮并解释。")
check("buildPrompt 百分号安全", S.buildPrompt("100%纯") == "查询100%纯并解释。")
S.resetPrompt()
check("resetPrompt", not S.isPromptCustom() and S.getPrompt() == S.DEFAULT_PROMPT)

-- thinking get/set
S.setThinking("high")
check("thinking set/get", S.getThinking() == "high")
S.setThinking("off")

-- ajbk_net.lua
local N = dofile([[@@BASE@@/ajbk_net.lua]])
check("joinURL 常规", N.joinURL("https://api.deepseek.com/v1", "models") == "https://api.deepseek.com/v1/models")
check("joinURL 尾斜杠", N.joinURL("https://host/v1beta/openai/", "chat/completions") == "https://host/v1beta/openai/chat/completions")

local t1 = N.buildThinkingParams("thinking_type", "off")
check("thinking_type off", t1.thinking.type == "disabled")
local t2 = N.buildThinkingParams("thinking_type", "low")
check("thinking_type low→enabled", t2.thinking.type == "enabled")
local t3 = N.buildThinkingParams("enable_thinking", "off")
check("enable_thinking off", t3.enable_thinking == false)
local t4 = N.buildThinkingParams("enable_thinking", "medium")
check("enable_thinking medium→true", t4.enable_thinking == true)
local t5 = N.buildThinkingParams("reasoning_effort", "off")
check("reasoning_effort off→nil", t5 == nil)
local t6 = N.buildThinkingParams("reasoning_effort", "high")
check("reasoning_effort high", t6.reasoning_effort == "high")
local t7 = N.buildThinkingParams("openrouter_reasoning", "off")
check("openrouter off", t7.reasoning.enabled == false)
local t8 = N.buildThinkingParams("openrouter_reasoning", "low")
check("openrouter low", t8.reasoning.effort == "low")
check("未映射样式→nil", N.buildThinkingParams("model_choice", "off") == nil)

local pp = N.postProcess
check("postProcess 思考块", pp("<think>推理</think>饕餮，tāo tiè。") == "饕餮，tāo tiè。")
check("postProcess 未闭合思考", pp("<think>推理中…") == "")
check("postProcess Markdown", pp("**饕餮**：`tāo tiè`") == "饕餮：tāo tiè")
check("postProcess 标题行", pp("\n# 释义\n大鼎。\n") == "释义\n大鼎。")
check("postProcess 空行压缩", pp("甲\n\n\n\n\n乙") == "甲\n\n乙")
check("postProcess 空输入", pp(nil) == "")
'''.replace("@@BASE@@", BASE).replace("@@TMP@@", TMP))

results = lua.globals().results
n_fail = 0
for i in range(1, len(results) + 1):
    line = results[i]
    print(line)
    if line.startswith("FAIL"):
        n_fail += 1
print(f"\n== {len(results)} checks, {n_fail} failed ==")
sys.exit(1 if n_fail else 0)
