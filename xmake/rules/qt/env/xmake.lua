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
-- @file        xmake.lua
--

-- define rule: environment
rule("qt.env")

    -- before load
    before_load(function (target)
        
        -- imports
        import("detect.sdks.find_qt")

        -- find qt sdk
        local qt = target:data("qt")
        if not qt then
            qt = assert(find_qt(nil, {verbose = true}), "Qt SDK not found!")
            target:data_set("qt", qt)
        end
        if is_plat("windows") or (is_plat("mingw") and is_host("windows")) then
            target:add("runenvs", "PATH", qt.bindir)
            target:add("runenvs", "QML2_IMPORT_PATH", path.join(qt.sdkdir, "qml"))
            target:add("runenvs", "QML_IMPORT_TRACE", "1")
        end
    end)


