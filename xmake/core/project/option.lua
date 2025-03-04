--!A cross-platform build utility based on Lua
--
-- Licensed under the Apache License, Version 2.0 (the "License");
-- you may not use this file except in compliance with the License.
-- You may obtain a copy of the License at
--
--     http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.
-- 
-- Copyright (C) 2015 - 2019, TBOOX Open Source Group.
--
-- @author      ruki
-- @file        option.lua
--

-- define module
local option = option or {}
local _instance = _instance or {}

-- load modules
local io             = require("base/io")
local os             = require("base/os")
local path           = require("base/path")
local table          = require("base/table")
local utils          = require("base/utils")
local baseoption     = require("base/option")
local global         = require("base/global")
local scopeinfo      = require("base/scopeinfo")
local interpreter    = require("base/interpreter")
local config         = require("project/config")
local cache          = require("project/cache")
local linker         = require("tool/linker")
local compiler       = require("tool/compiler")
local sandbox        = require("sandbox/sandbox")
local language       = require("language/language")
local sandbox        = require("sandbox/sandbox")
local sandbox_module = require("sandbox/modules/import/core/sandbox/module")

-- new an instance
function _instance.new(name, info)
    local instance = table.inherit(_instance)
    instance._NAME = name
    instance._INFO = info
    return instance
end

-- save the option info to the cache
function _instance:_save()

    -- clear scripts for caching to file    
    self:set("check", nil)
    self:set("check_after", nil)
    self:set("check_before", nil)

    -- save option
    option._cache():set(self:name(), self:info())
end

-- clear the option info for cache
function _instance:_clear()
    option._cache():set(self:name(), nil)
end

-- check option conditions
function _instance:_do_check()

    -- import check_cxsnippets()
    self._check_cxsnippets = self._check_cxsnippets or sandbox_module.import("lib.detect.check_cxsnippets", {anonymous = true})

    -- check for c and c++
    local passed = nil
    for _, kind in ipairs({"c", "cxx"}) do

        -- get conditions
        local links    = self:get("links")
        local snippets = self:get(kind .. "snippets") 
        local types    = self:get(kind .. "types")
        local funcs    = self:get(kind .. "funcs")
        local includes = self:get(kind .. "includes")

        -- TODO it is deprecated
        local snippet  = self:get(kind .. "snippet") 
        if snippet then
            snippets = table.join(snippets or {}, snippet)
        end

        -- need check it?
        if snippets or types or funcs or links or includes then

            -- init source kind
            local sourcekind = kind
            if kind == "c" then
                sourcekind = "cc"
            end

            -- check it
            local ok, results_or_errors = sandbox.load(self._check_cxsnippets, snippets, {target = self, sourcekind = sourcekind, types = types, funcs = funcs, includes = includes})
            if not ok then
                return false, results_or_errors
            end

            -- passed?
            if results_or_errors then
                passed = true
            else
                passed = false
                break
            end
        end
    end

    -- check features
    local features = self:get("features")
    if features then

        -- import core.tool.compiler
        self._core_tool_compiler = self._core_tool_compiler or sandbox_module.import("core.tool.compiler", {anonymous = true})

        -- all features are supported?
        local features_supported = self._core_tool_compiler.has_features(features, {target = self})
        if features_supported and #features_supported == #features then
            passed = true
        end

        -- trace
        if baseoption.get("verbose") or baseoption.get("diagnosis") then
            for _, feature in ipairs(table.wrap(features)) do
                utils.cprint("${dim}checking for the feature(%s) ... %s", feature, passed and "${color.success}${text.success}" or "${color.nothing}${text.nothing}")
            end
        end
    end

    -- enable this option if be passed
    if passed then
        self:enable(true)
    end

    -- ok
    return true
end

-- on check
function _instance:_on_check()

    -- get check script
    local check = self:script("check")
    if check then
        return sandbox.load(check, self)
    else
        return self:_do_check()
    end
end

-- check option 
function _instance:_check()

    -- disable this option first
    self:enable(false)

    -- check it
    local ok, errors = self:_on_check()

    -- get name
    local name = self:name()
    if name:startswith("__") then
        name = name:sub(3)
    end

    -- trace
    utils.cprint("checking for the %s ... %s", name, self:enabled() and "${color.success}${text.success}" or "${color.nothing}${text.nothing}")
    if not ok then
        os.raise(errors)
    end

    -- flush io buffer to update progress info
    io.flush()
end

-- attempt to check option 
function _instance:check()

    -- the option name
    local name = self:name()

    -- get default value, TODO: enable will be deprecated
    local default = self:get("default")
    if default == nil then
        default = self:get("enable")
    end

    -- before and after check
    local check_before = self:script("check_before")
    local check_after  = self:script("check_after")
    if check_before then
        check_before(self)
    end

    -- need check? (only force to check the automatical option without the default value)
    if config.get(name) == nil or default == nil then

        -- use it directly if the default value exists
        if default ~= nil then
            self:set_value(default)
        -- check option as boolean switch automatically if the default value not exists
        elseif default == nil then
            self:_check()
        -- disable this option in other case
        else
            self:enable(false)
        end

    -- need not check? only save this option to configuration directly
    elseif config.get(name) then
        self:_save()
    end    

    -- after check
    if check_after then
        check_after(self)
    end
end

-- get the option value
function _instance:value()
    return config.get(self:name())
end

-- set the option value
function _instance:set_value(value)

    -- set value to option
    config.set(self:name(), value)

    -- save option 
    self:_save()
end

-- clear the option status and need recheck it
function _instance:clear()

    -- clear config
    config.set(self:name(), nil)

    -- clear this option in cache 
    self:_clear()
end

-- this option is enabled?
function _instance:enabled()
    return config.get(self:name())
end

-- enable or disable this option
--
-- @param enabled   enable option?
-- @param opt       the argument options, e.g. {readonly = true, force = false}
--
function _instance:enable(enabled, opt)

    -- init options
    opt = opt or {}

    -- enable or disable this option?
    if not config.readonly(self:name()) or opt.force then
        config.set(self:name(), enabled, opt)
    end

    -- save or clear this option in cache 
    if self:enabled() then
        self:_save()
    else
        self:_clear()
    end
end

-- get the option info
function _instance:info()
    return self._INFO:info()
end

-- get the type: option
function _instance:type()
    return "option"
end

-- get the option info
function _instance:get(name)
    return self._INFO:get(name)
end

-- set the value to the option info
function _instance:set(name, ...)
    self._INFO:apival_set(name, ...)
end

-- add the value to the option info
function _instance:add(name, ...)
    self._INFO:apival_add(name, ...)
end

-- remove the value to the option info
function _instance:del(name, ...)
    self._INFO:apival_del(name, ...)
end

-- get the extra configuration
function _instance:extraconf(name, item, key)
    return self._INFO:extraconf(name, item, key)
end

-- get the given dependent option
function _instance:dep(name)
    local deps = self:deps()
    if deps then
        return deps[name]
    end
end

-- get option deps
function _instance:deps()
    return self._DEPS
end

-- get option order deps
function _instance:orderdeps()
    return self._ORDERDEPS
end

-- get the option name
function _instance:name()
    return self._NAME
end

-- get xxx_script
function _instance:script(name)

    -- get script
    local script = self:get(name)

    -- imports some modules first
    if script then
        local scope = getfenv(script)
        if scope then
            for _, modulename in ipairs(table.wrap(self:get("imports"))) do
                scope[sandbox_module.name(modulename)] = sandbox_module.import(modulename, {anonymous = true})
            end
        end
    end

    -- ok
    return script
end

-- get cache
function option._cache()

    -- get it from cache first if exists
    if option._CACHE then
        return option._CACHE
    end

    -- init cache
    option._CACHE = cache("local.option")

    -- ok
    return option._CACHE
end

-- get option apis
function option.apis()

    return 
    {
        values =
        {
            -- option.set_xxx
            "option.set_values"
        ,   "option.set_default"
        ,   "option.set_showmenu"
        ,   "option.set_category"
        ,   "option.set_warnings"
        ,   "option.set_optimize"
        ,   "option.set_languages"
        ,   "option.set_description"
            -- option.add_xxx
        ,   "option.add_deps"
        ,   "option.add_imports"
        ,   "option.add_vectorexts"
        ,   "option.add_features"
        }
    ,   keyvalues =
        {
            -- option.set_xxx
            "option.set_configvar"
        }
    ,   script =
        {
            -- option.before_xxx
            "option.before_check"
            -- option.on_xxx
        ,   "option.on_check"
            -- option.after_xxx
        ,   "option.after_check"
        }
    }
end

-- get interpreter
function option.interpreter()

    -- the interpreter has been initialized? return it directly
    if option._INTERPRETER then
        return option._INTERPRETER
    end

    -- init interpreter
    local interp = interpreter.new()

    -- define apis for option
    interp:api_define(option.apis())

    -- define apis for language
    interp:api_define(language.apis())

    -- register filter handler
    interp:filter():register("option", function (variable)
 
        -- init maps
        local maps = 
        {
            arch       = function() return config.get("arch") or os.arch() end
        ,   plat       = function() return config.get("plat") or os.host() end
        ,   mode       = function() return config.get("mode") or "release" end
        ,   host       = os.host()
        ,   prefix     = "$(prefix)"
        ,   globaldir  = global.directory()
        ,   configdir  = config.directory()
        ,   projectdir = os.projectdir()
        ,   programdir = os.programdir()
        }

        -- map it
        local result = maps[variable]
        if type(result) == "function" then
            result = result()
        end
        return result
    end)

    -- save interpreter
    option._INTERPRETER = interp

    -- ok?
    return interp
end

-- new an option instance
function option.new(name, info)
    return _instance.new(name, info)
end

-- load the option info from the cache
function option.load(name)

    -- check
    assert(name)

    -- get info
    local info = option._cache():get(name)
    if info == nil then
        return 
    end
    return option.new(name, scopeinfo.new("option", info))
end

-- save all options to the cache file
function option.save()
    option._cache():flush()
end

-- return module
return option
