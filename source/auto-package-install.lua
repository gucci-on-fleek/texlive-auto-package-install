-- texlive-auto-package-install
-- https://github.com/gucci-on-fleek/texlive-auto-package-install
-- SPDX-License-Identifier: MPL-2.0+
-- SPDX-FileCopyrightText: 2026 Max Chernoff

----------------------
--- Initialization ---
----------------------

local name = "auto-package-install"
luatexbase.provides_module {
    name = name,
    date = "2026/01/20", --%%slashdate
    version = "0.0.0", --%%version
    description = "Automatically installs missing LaTeX packages from TeX Live",
}


-----------------
--- Constants ---
-----------------

local string_catcodes = token.create("c_str_cctab").mode
local font_extension_to_kpse_type = {
    otf = "opentype fonts",
    ttc = "truetype fonts",
    ttf = "truetype fonts",
    afm = "afm",
    pfb = "type1 fonts",
    tfm = "tfm",
}
local font_extension_order = { "otf",  "ttc", "ttf", "afm", "pfb", "tfm" }
local now = os.time()
local yesterday = now - 86400


-----------------------------------------
--- General-purpose Utility Functions ---
-----------------------------------------

--- Raise a TeX error from Lua
--- @param message string The error message
--- @return nil
local function tex_error(message)
    luatexbase.module_error(name, message)
end

--- Creates a TeX command that evaluates a Lua function
---
--- @param name string The name of the `\csname` to define
--- @param func function
--- @param args table<string> The TeX types of the function arguments
--- @param index integer|nil The index to use for the Lua function (if `nil`,
---                          a new index is created)
--- @return nil
local function register_tex_cmd(name, func, args, index)
    -- Mangle the name to the internal expl3 form.
    if not name:match("[:@]") then
        local argument_spec = {}
        for i, arg in ipairs(args) do
            if arg == "token" then
                argument_spec[i] = "N"
            else
                argument_spec[i] = "n"
            end
        end

        name = "__autopkg_" .. name .. ":" .. table.concat(argument_spec)
    end

    -- Push the appropriate scanner functions onto the scanning stack.
    local scanners = {}
    for i, arg in ipairs(args) do
        if arg == "token" then
            scanners[i] = token.get_next
        else
            scanners[i] = token["scan_" .. arg]
        end
    end

    -- An intermediate function that properly "scans" for its arguments
    -- in the TeX side.
    local scanning_func = function()
        local values = {}
        for i, scanner in ipairs(scanners) do
            values[i] = scanner()
        end

        func(table.unpack(values))
    end

    -- Actually register the function
    if not index then
        index = luatexbase.new_luafunction(name)
    end
    lua.get_functions_table()[index] = scanning_func

    token.set_lua(name, index)
end


---------------
--- Parsing ---
---------------

local parse_ctan_files do
    local P, R, S, C, Ct, Cg, Cf, Cc =
        lpeg.P, lpeg.R, lpeg.S, lpeg.C, lpeg.Ct, lpeg.Cg, lpeg.Cf, lpeg.Cc
    local os_time, tonumber = os.time, tonumber

    local year = S("12") * S("9012") * R("09") * R("09")
    local month = S("01") * R("09")
    local day = S("0123") * R("09")
    local date = Ct(
        Cg(year, "year") * P("/") *
        Cg(month, "month") * P("/") *
        Cg(day, "day")
    )

    local size = S(" \t")^0 * C(R("09")^1)

    local path_component = 1 - S("/\n")
    local path = C(
        (path_component^1 * P("/"))^0 *
        C(path_component^1)
    )

    local column_separator = P(" | ")
    local line = Ct(
        (date / os_time) * column_separator *
        (size / 0) * column_separator *
        path *
        P("\n")
    )

    local lines = Cf(Cc({}) * line^0, function(t, line)
        t[line[3]] = line
        return t
    end)

    --- @class (exact) ctan_files: table A table representing a token.
    --- @field [1] integer (time) The modification time as a Unix timestamp
    --- @field [2] string  (path) The full path to the file on CTAN
    --- @field [3] string  (name) The name of the file

    --- Parse CTAN `FILES.byname` data
    --- @param data string The contents of a `FILES.byname` file
    --- @return table<string, ctan_files> files A table mapping file names to their
    ---    paths on CTAN
    function parse_ctan_files(data)
        return lines:match(data)
    end
end

parse_ctan_files(io.loaddata("/tmp/tmp.H8J6SVHbeh/FILES.byname"))
os.exit(0)

-------------
--- Hooks ---
-------------

--- @type table<string, fun(caller: string, asked_name: string):(found_name: string|nil)>
--- A table of hook functions for file finding. If you return a string, the
--- search will immediately return that string; if you return `nil`, the default
--- search will be performed.
local before_hooks = {}

--- @type table<string, fun(caller: string, asked_name: string, found_name: string|nil):(found_name: string|nil)>
--- A table of hook functions for file finding. These are called after the
--- default search is performed. Whatever you return will be used exactly as the
--- result of the search.
local after_hooks = {}

--- The main hook function
--- @param caller string The name of the function that called this hook
--- @param asked_name string The name of the file being searched for
--- @param fallback_func fun(asked_name: string):(found_name: string|nil) The
---        fallback function to call to perform the search if no before-hooks
---        return a result
--- @return string|nil found_name The (possibly modified) name of the file found
local function hook(caller, asked_name, fallback_func)
    local before_func = before_hooks[caller] or before_hooks["default"]
    local found_name = before_func(caller, asked_name)
    if found_name then
        return found_name
    end

    found_name = fallback_func(asked_name)

    local after_func = after_hooks[caller] or after_hooks["default"]
    found_name = after_func(caller, asked_name, found_name)

    return found_name
end

--- A wrapper function for hooks
--- @param caller string The name of the function that called this hook
--- @param fallback_func fun(asked_name: string):(found_name: string|nil) The
----       fallback function to call to perform the search if no before-hooks
---        return a result
--- @return fun(asked_name: string):(found_name: string|nil) - A function that
---         takes the asked name and returns the found name
local function hook_wrapper(caller, fallback_func)
    return function(asked_name)
        return hook(caller, asked_name, fallback_func)
    end
end

--- The default before hook
--- @param caller string The name of the function that called this hook
--- @param asked_name string The name of the file being searched for
--- @return nil found_name Always returns `nil`
function before_hooks.default(caller, asked_name)
    print(">>>", caller, asked_name)
    return nil
end

--- The default after hook
--- @param caller string The name of the function that called this hook
--- @param asked_name string The name of the file being searched for
--- @param found_name string|nil The name of the file found, or `nil`
--- @return string|nil found_name Passes through the found name unchanged
function after_hooks.default(caller, asked_name, found_name)
    print("<<<", caller, asked_name, found_name)
    return found_name
end

-----------------
--- Callbacks ---
-----------------

local callbacks = {}

function callbacks.find_read_file(id_number, asked_name)
    return hook(
        "find_read_file",
        asked_name,
        function(name)
            return kpse.find_file(name, "tex", false)
        end
    )
end

callbacks.find_font_file = hook_wrapper(
    "find_font_file",
    function(asked_name)
        local extension = file.suffix(asked_name)
        local kpse_type = font_extension_to_kpse_type[extension]
        if not kpse_type then
            return nil
        end
        return kpse.find_file(asked_name, kpse_type, false)
    end
)

callbacks.find_opentype_file = hook_wrapper(
    "find_opentype_file",
    function(name)
        return kpse.find_file(name, "opentype fonts", false)
    end
)

callbacks.find_truetype_file = hook_wrapper(
    "find_truetype_file",
    function(name)
        return kpse.find_file(name, "truetype fonts", false)
    end
)

callbacks.find_type1_file = hook_wrapper(
    "find_type1_file",
    function(name)
        return kpse.find_file(name, "type1 fonts", false)
    end
)

-- Overwrite the luaotfload font file finding callback function to use our own
-- resolver
function fonts.names.lookup_font_file(asked_name)
    local path = hook(
        "fonts.names.lookup_font_file",
        asked_name,
        function(asked_name)
            for _, ext in ipairs(font_extension_order) do
                local path = kpse.find_file(
                    asked_name,
                    font_extension_to_kpse_type[ext],
                    false
                )
                if path then
                    return path
                end
            end
            return nil
        end
    )

    if path then
        return path, nil, true
    else
        return asked_name, nil, false
    end
end

--------------------
--- TeX Commands ---
--------------------

-- Overwrite the internal expl3 \tex_filesize:D Lua-based command to look up
-- the file using our own resolvers, so that \IfFileExists works correctly.
register_tex_cmd(
    "tex_filesize:D",
    function(filename)
        -- Look up the file
        local path = hook("tex_filesize:D", filename, function(name)
            return kpse.find_file(name, "tex", false)
        end)
        if not path then
            return
        end

        -- Get the file size
        local size = lfs.attributes(path, "size")
        if not size then
            return
        end

        tex.sprint(string_catcodes, tostring(size))
    end,
    { "string" },
    token.create("tex_filesize:D").mode
)

-- Command to enable the callbacks
register_tex_cmd("enable", function()
    for callback, func in pairs(callbacks) do
        luatexbase.add_to_callback(callback, func, name .. "." .. callback)
    end
end, { })

-- Command to disable the callbacks
register_tex_cmd("disable", function()
    for callback, func in pairs(callbacks) do
        if luatexbase.in_callback(callback, name .. "." .. callback) then
            luatexbase.remove_from_callback(callback, name .. "." .. callback)
        end
    end
end, { })
