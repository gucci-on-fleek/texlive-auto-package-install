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

-- Save some globals for a slight speed boost
local tonumber = tonumber
local pairs = pairs
local ipairs = ipairs
local max = math.max

-- Used for tex.sprint
local string_catcodes = token.create("c_str_cctab").mode

-- Font type handling
local font_extension_to_kpse_type = {
    otf = "opentype fonts",
    ttc = "truetype fonts",
    ttf = "truetype fonts",
    afm = "afm",
    pfb = "type1 fonts",
    tfm = "tfm",
}
local font_extension_order = { "otf",  "ttc", "ttf", "afm", "pfb", "tfm" }

-- The current time
local now = os.time()
local yesterday = now - 86400

-- Hard coded for now
local texlive_url = "http://www.tug.org/.texlive/texmf-dist/"
local tlpdb_url = "http://www.tug.org/.texlive/tlpkg/texlive.tlpdb"

-- Set the user agent for HTTP requests
--- @diagnostic disable-next-line: undefined-field
socket.http.USERAGENT = "texlive-auto-package-install/0.0.0 (+https://github.com/gucci-on-fleek/texlive-auto-package-install)" --%%version

-- The file name of the TeX Live files cache
local texlive_files_cache_name = "texlive-files.luc.gz"

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

--- Perform an HTTP GET request to the TeX Live server
--- @param path string The path to request
--- @return string|nil body The response body, or `nil` on failure
--- @return integer|nil status The HTTP status code
--- @return table<string, string>|nil headers The response headers
local function texlive_get(path)
    --- @diagnostic disable-next-line: undefined-field
    return socket.http.request(texlive_url .. path)
end

local cache_path do
    local cache_root --- @type string|nil

    --- Gets the path to a file in the cache directory
    --- @param path string The path to a file relative to a TEXMF
    --- @return string path The absolute path to the file in the cache directory
    function cache_path(path)
        if not cache_root then
            local caches = kpse.expand_path("$TEXMFCACHE"):split(":") --- @cast caches string[]
            for _, cache in ipairs(caches) do
                if not kpse.out_name_ok_silent_extended(cache) then
                    goto continue
                end
                if not file.is_writable(cache) then
                    goto continue
                end
                cache_root = cache .. "/" .. name .. "/"
                break
                ::continue::
            end

            if not cache_root then
                tex_error("Could not find a writable TEXMFCACHE directory")
            end
        end

        local full_path = cache_root .. path
        local dirname = file.pathpart(full_path)
        lfs.mkdirp(dirname) --- @diagnostic disable-line: undefined-field
        return full_path
    end
end

--- Serialize a table to a compressed binary string
--- @param t table The table to serialize
--- @return string compressed The compressed binary string
local function table_to_binary(t)
    local str = table.serialize(t, true)
    local func, err = load(str, "t")
    if not func then
        error("Could not serialize table: " .. tostring(err))
    end

    local binary = string.dump(func, true)
    local compressed = gzip.compress(binary) --- @cast compressed string
    return compressed
end

--- Deserialize a table from a compressed binary string
--- @param compressed string The compressed binary string
--- @return table t The deserialized table
local function binary_to_table(compressed)
    local binary = gzip.decompress(compressed) --- @cast binary string
    local func, err = load(binary, "b")
    if not func then
        error("Could not deserialize table: " .. tostring(err))
    end
    local t = func() --- @cast t table
    return t
end


----------------------
--- TeX Live Files ---
----------------------

local newest_revision = 0
local texlive_files = table.setmetatableindex(function(t, name)
    local cache_file = cache_path(texlive_files_cache_name)
    -- Skip if the cache has already been populated
    if next(t) then
        -- pass
    -- Fetch from TeX Live if the cache is missing or stale
    elseif (not io.exists(cache_file)) or
           (lfs.attributes(cache_file, "modification") < yesterday)
    then
        -- Fetch from TeX Live
        --- @diagnostic disable-next-line: undefined-field
        local body, status = socket.http.request(tlpdb_url)
        if not body or status ~= 200 then
            tex_error("Could not fetch TeX Live file list (HTTP status " .. tostring(status) .. ")")
            return -- (Unreachable)
        end

        local files = {}
        for _, section in ipairs(body:split("\n\n")) do
            local revision = tonumber(section:match("revision (%d+)"))
            newest_revision = max(newest_revision, revision or 0)
            for path, name in section:gmatch("\n texmf%-dist/([^ \n]+/([^/ \n]+))") do
                files[name] = { path, revision }
            end
        end

        -- Copy into the table
        table.merge(t, files)

        -- Save to cache
        local compressed = table_to_binary {
            newest_revision = newest_revision,
            files = files,
        }
        io.savedata(cache_file, compressed)

    -- Load from the cache otherwise
    else
        -- Load from cache
        local compressed = io.loaddata(cache_file)
        if not compressed then
            tex_error("Could not read CTAN files cache")
            return -- (Unreachable)
        end
        local data = binary_to_table(compressed)

        -- Copy into the table
        table.merge(t, data.files)
        newest_revision = data.newest_revision

        inspect(t)
    end

    return rawget(t, name)
end)


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
    inspect(texlive_files[asked_name])
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
