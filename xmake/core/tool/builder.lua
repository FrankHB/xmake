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
-- @file        builder.lua
--

-- define module
local builder = builder or {}

-- load modules
local io       = require("base/io")
local path     = require("base/path")
local utils    = require("base/utils")
local table    = require("base/table")
local string   = require("base/string")
local option   = require("base/option")
local tool     = require("tool/tool")
local config   = require("project/config")
local sandbox  = require("sandbox/sandbox")
local language = require("language/language")
local platform = require("platform/platform")

-- get the tool of builder
function builder:_tool()
    return self._TOOL
end

-- get the name flags
function builder:_nameflags()
    return self._NAMEFLAGS
end

-- get the target kind
function builder:_targetkind()
    return self._TARGETKIND
end

-- map gcc flag to the given builder flag
function builder:_mapflag(flag, flagkind, mapflags)

    -- attempt to map it directly
    local flag_mapped = mapflags[flag]
    if flag_mapped then
        return flag_mapped
    end

    -- find and replace it using pattern
    for k, v in pairs(mapflags) do
        local flag_mapped, count = flag:gsub("^" .. k .. "$", function (w) return v end)
        if flag_mapped and count ~= 0 then
            return utils.ifelse(#flag_mapped ~= 0, flag_mapped, nil) 
        end
    end

    -- has this flag?
    if self:has_flags(flag, flagkind) then
        return flag
    end
end

-- map gcc flags to the given builder flags
function builder:_mapflags(flags, flagkind)

    -- wrap flags first
    flags = table.wrap(flags)

    -- done
    local results = {}
    local mapflags = self:get("mapflags")
    if mapflags then

        -- map flags
        for _, flag in pairs(flags) do
            local flag_mapped = self:_mapflag(flag, flagkind, mapflags)
            if flag_mapped then
                table.insert(results, flag_mapped)
            end
        end

    else

        -- has flags?
        for _, flag in pairs(flags) do
            if self:has_flags(flag, flagkind) then
                table.insert(results, flag)
            end
        end

    end

    -- ok?
    return results
end

-- get the flag kinds
function builder:_flagkinds()
    return self._FLAGKINDS
end

-- inherit links from target deps
function builder:_inherit_links_from_targetdeps(results, target, flagname)

    -- for all target deps
    local orderdeps = target:orderdeps()
    local total = #orderdeps
    for idx, _ in ipairs(orderdeps) do

        -- reverse deps order for links
        local dep = orderdeps[total + 1 - idx]

        -- is static or shared target library? link it
        local depkind      = dep:targetkind()
        local targetkind   = target:targetkind()
        local depinherit   = target:extraconf("deps", dep:name(), "inherit")
        if (depkind == "static" or depkind == "shared" or depkind == "object") and (depinherit == nil or depinherit) then
            if (flagname == "links" or flagname == "syslinks") and (targetkind == "binary" or targetkind == "shared") then

                -- add dependent link
                if depkind ~= "object" then
                    table.insert(results, dep:basename())
                end

                -- inherit links from the depdent target
                self:_add_values_from_target(results, dep, flagname)

            elseif flagname == "linkdirs" and (targetkind == "binary" or targetkind == "shared") then

                -- add dependent linkdirs
                if depkind ~= "object" then
                    table.insert(results, path.directory(dep:targetfile()))
                end

                -- inherit linkdirs from the depdent target
                self:_add_values_from_target(results, dep, flagname)

            elseif flagname == "rpathdirs" and (targetkind == "binary" or targetkind == "shared") then

                -- add dependent rpathdirs 
                if depkind ~= "object" then
                    local rpathdir = "@loader_path"
                    local subdir = path.relative(path.directory(dep:targetfile()), path.directory(target:targetfile()))
                    if subdir and subdir ~= '.' then
                        rpathdir = path.join(rpathdir, subdir)
                    end
                    table.insert(results, rpathdir)
                end

            elseif flagname == "includedirs" then

                -- TODO add dependent headerdir (deprecated)
                if dep:get("headers") and os.isdir(dep:headerdir()) then
                    table.insert(results, dep:headerdir())
                end

                -- add dependent header directories
                local headerdirs = dep:get("headerdirs")
                if headerdirs then
                    table.join2(results, headerdirs)
                end
                
                -- add dependent configheader directory
                local configheader = dep:configheader()
                if configheader and os.isfile(configheader) then
                    table.insert(results, path.directory(configheader))
                end
            end
        end
    end
end

-- inherit flags (only for public/interface) from target deps
--
-- e.g. 
-- add_cflags("", {public = true})
-- add_cflags("", {interface = true})
--
function builder:_inherit_flags_from_targetdeps(flags, target)
    local orderdeps = target:orderdeps()
    local total = #orderdeps
    for idx, _ in ipairs(orderdeps) do
        local dep = orderdeps[total + 1 - idx]
        local depinherit = target:extraconf("deps", dep:name(), "inherit")
        if depinherit == nil or depinherit then
            for _, flagkind in ipairs(self:_flagkinds()) do
                self:_add_flags_from_flagkind(flags, dep, flagkind, {interface = true})
            end
        end
    end
end

-- inherit values (only for public/interface) from target deps
--
-- e.g. 
-- add_defines("", {public = true})
-- add_defines("", {interface = true})
--
function builder:_inherit_values_from_targetdeps(values, target, name)
    local orderdeps = target:orderdeps()
    local total = #orderdeps
    for idx, _ in ipairs(orderdeps) do
        local dep = orderdeps[total + 1 - idx]
        local depinherit = target:extraconf("deps", dep:name(), "inherit")
        if depinherit == nil or depinherit then
            table.join2(values, dep:get(name, {interface = true}))
        end
    end
end

-- add values from target
function builder:_add_values_from_target(values, target, name)
    table.join2(values, target:get(name))
    if target:type() == "target" then
        self:_add_values_from_targetopts(values, target, name)
        self:_add_values_from_targetpkgs(values, target, name)
    end
end

-- add values from target options
function builder:_add_values_from_targetopts(values, target, name)
	for _, opt in ipairs(target:orderopts()) do
		table.join2(values, table.wrap(opt:get(name)))
	end
end

-- add values from target packages
function builder:_add_values_from_targetpkgs(values, target, name)
    for _, pkg in ipairs(target:orderpkgs()) do
        -- uses them instead of the builtin configs if exists extra package config
        -- e.g. `add_packages("xxx", {links = "xxx"})`
        local configinfo = target:pkgconfig(pkg:name())
        if configinfo and configinfo[name] then
            table.join2(values, configinfo[name])
        else
            -- uses the builtin package configs
            table.join2(values, pkg:get(name))
        end
    end
end

-- add flags from the flagkind 
function builder:_add_flags_from_flagkind(flags, target, flagkind, opt)
    local targetflags = target:get(flagkind, opt)
    local extraconf   = target:extraconf(flagkind)
    if extraconf then
        for _, flag in ipairs(table.wrap(targetflags)) do
            -- force to add flags?
            local flagconf = extraconf[flag]
            if flagconf and flagconf.force then
                table.join2(flags, flag)
            else
                table.join2(flags, self:_mapflags(flag, flagkind))
            end
        end
    else
        table.join2(flags, self:_mapflags(targetflags, flagkind))
    end
end

-- add flags from the configure 
function builder:_add_flags_from_config(flags)
    for _, flagkind in ipairs(self:_flagkinds()) do
        table.join2(flags, config.get(flagkind))
    end
end

-- add flags from the option 
function builder:_add_flags_from_option(flags, opt)
    for _, flagkind in ipairs(self:_flagkinds()) do
        self:_add_flags_from_flagkind(flags, opt, flagkind)
    end
end

-- add flags from the package 
function builder:_add_flags_from_package(flags, pkg)
    for _, flagkind in ipairs(self:_flagkinds()) do
        table.join2(flags, self:_mapflags(pkg:get(flagkind), flagkind))
    end
end

-- add flags from the target 
function builder:_add_flags_from_target(flags, target)

    -- no target?
    if not target then
        return
    end
 
    -- init cache
    self._TARGETFLAGS = self._TARGETFLAGS or {}
    local cache = self._TARGETFLAGS

    -- get flags from cache first
    local key = tostring(target)
    local targetflags = cache[key]
    if not targetflags then
    
        -- add flags from language
        targetflags = {}
        self:_add_flags_from_language(targetflags, target)

        -- add flags for the target 
        if target:type() == "target" then

            -- add flags from options
            for _, opt in ipairs(target:orderopts()) do
                self:_add_flags_from_option(targetflags, opt)
            end

            -- add flags from packages
            for _, pkg in ipairs(target:orderpkgs()) do
                self:_add_flags_from_package(targetflags, pkg)
            end

            -- inherit flags (public/interface) from all dependent targets
            self:_inherit_flags_from_targetdeps(targetflags, target)
        end

        -- add the target flags 
        for _, flagkind in ipairs(self:_flagkinds()) do
            self:_add_flags_from_flagkind(targetflags, target, flagkind)
        end

        -- cache it
        cache[key] = targetflags
    end

    -- add flags
    table.join2(flags, targetflags)
end

-- add flags from the argument option 
function builder:_add_flags_from_argument(flags, target, args)

    -- add flags from the flag kinds (cxflags, ..)
    for _, flagkind in ipairs(self:_flagkinds()) do

        -- add auto mapping flags
        table.join2(flags, self:_mapflags(args[flagkind], flagkind))

        -- add original flags
        local original_flags = (args.force or {})[flagkind]
        if original_flags then
            table.join2(flags, original_flags)
        end
    end

    -- add flags (named) from the language 
    if target then
        local key = target:type()
        self:_add_flags_from_language(flags, target, {[key] = function (name) return args[name] end})
    else
        self:_add_flags_from_language(flags, nil, {target = function (name) return args[name] end})
    end
end

-- add flags from the language 
function builder:_add_flags_from_language(flags, target, getters)

    -- init getters
    --
    -- e.g.
    --
    -- target.linkdirs => flags = getters("target")("linkdirs")
    --
    local getters = getters or
    {
        config      =   function (name)
                            local values = config.get(name)
                            if values and name:endswith("dirs") then
                                values = path.splitenv(values)
                            end
                            return values
                        end
    ,   platform    =   platform.get
    ,   target      =   function (name) 

                            -- only for target
                            local results = {}
                            if target:type() == "target" then

                                -- link? add includes and links of all dependent targets first
                                if name == "links" or name == "syslinks" or name == "linkdirs" or name == "rpathdirs" or name == "includedirs" then
                                    self:_inherit_links_from_targetdeps(results, target, name)
                                end

                                -- inherit flagvalues (public or interface) of all dependent targets
                                self:_inherit_values_from_targetdeps(results, target, name)

                                -- get flagvalues of target with given flagname
                                table.join2(results, target:get(name))
                            end
                            return results
                        end
    ,   option      =   function (name)

                            -- is target? get flagvalues of the attached options and packages
                            local results = {}
                            if target:type() == "target" then
								self:_add_values_from_targetopts(results, target, name)
                                self:_add_values_from_targetpkgs(results, target, name)

                            -- is option? get flagvalues of option with given flagname
                            elseif target:type() == "option" then
                                table.join2(results, target:get(name))
                            end
                            return results
                        end
    }

    -- get name flags for builder
    for _, flaginfo in ipairs(self:_nameflags()) do

        -- get flag info
        local flagscope     = flaginfo[1]
        local flagname      = flaginfo[2]
        local checkstate    = flaginfo[3]

        -- get getter
        local getter = getters[flagscope]
        if getter then

            -- get api name of tool 
            --
            -- ignore "nf_" and "_if_ok"
            --
            -- e.g.
            --
            -- defines => define
            -- defines_if_ok => define
            -- ...
            --
            local apiname = flagname:gsub("^nf_", ""):gsub("_if_ok$", "")
            if apiname:endswith("s") then
                apiname = apiname:sub(1, #apiname - 1)
            end

            -- map name flag to real flag
            local mapper = self:_tool()["nf_" .. apiname]
            if mapper then
                
                -- add the flags 
                for _, flagvalue in ipairs(table.wrap(getter(flagname))) do

                    -- map and check flag
                    local flag = mapper(self:_tool(), flagvalue, target, self:_targetkind())
                    if flag and flag ~= "" and (not checkstate or self:has_flags(flag)) then
                        table.join2(flags, flag)
                    end
                end
            end
        end
    end
end

-- preprocess flags
function builder:_preprocess_flags(flags)

    -- remove repeat
    flags = table.unique(flags)

    -- split flag group, e.g. "-I /xxx" => {"-I", "/xxx"}
    local results = {}
    for _, flag in ipairs(flags) do
        flag = flag:trim()
        if #flag > 0 then
            if flag:find(" ", 1, true) then
                table.join2(results, os.argv(flag))
            else
                table.insert(results, flag)
            end
        end
    end

    -- get it
    return results 
end

-- get tool name
function builder:name()
    return self:_tool():name()
end

-- get tool kind
function builder:kind()
    return self:_tool():kind()
end

-- get tool program
function builder:program()
    return self:_tool():program()
end

-- get properties of the tool
function builder:get(name)
    return self:_tool():get(name)
end

-- has flags?
function builder:has_flags(flags, flagkind)
    return self:_tool():has_flags(flags, flagkind)
end

-- get the format of the given target kind 
function builder:format(targetkind)

    -- get formats
    local formats = self:get("formats")
    if formats then
        return formats[targetkind]
    end
end

-- get buildmode of the tool
function builder:buildmode(name)

    -- get it
    local buildmodes = self:get("buildmodes")
    if buildmodes then
        return buildmodes[name]
    end
end

-- return module
return builder
