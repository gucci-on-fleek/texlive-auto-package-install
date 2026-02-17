-- texlive-auto-package-install
-- https://github.com/gucci-on-fleek/texlive-auto-package-install
-- SPDX-License-Identifier: MPL-2.0+
-- SPDX-FileCopyrightText: 2026 Max Chernoff

--- This subpackage contains the code used to interact with TeX, most notably the
--- code that hooks into the LuaTeX callbacks to detect missing files and install
--- them.

----------------------
--- Initialization ---
----------------------

-- Make sure that the main package file is loaded first
assert(
    netinst._currently_loading_subpackages,
    "This file cannot be loaded directly."
)
netinst._utils.debug("hooks subpackage loaded")


-----------------
--- Constants ---
-----------------

local font_extension_to_kpse_type = {
    otf = "opentype fonts",
    ttc = "truetype fonts",
    ttf = "truetype fonts",
    afm = "afm",
    pfb = "type1 fonts",
    tfm = "tfm",
}
local font_extension_order = { "otf",  "ttc", "ttf", "afm", "pfb", "tfm" }
local insert = table.insert
local string_catcodes = token.create("c_str_cctab").mode


-------------
--- Hooks ---
-------------

--- @alias hook_function fun(asked_name: string, found_path: string|nil):(found_path: string|nil)

--- @class (exact) hooks
--- A table of hook functions for file finding. If you return a string, the
--- search will immediately return that string; if you return `nil`, the default
--- search will be performed.
---
--- @field before hook_function
---     The function that will be called before TeX searches for a file.
---
--- @field after hook_function
---     The function that will be called after TeX searches for a file.
netinst.hooks = {}

--- The default function that will be called before TeX searches for a file.
--- @type hook_function
--- @param asked_name string
---     The name of the file that TeX is looking for, as given in the TeX
---     source.
---
--- @param found_path nil Always `nil`.
--- @return string|nil found_path
---     The name of the file that TeX should use, or `nil` if it could not be
---     found. If you return a string here, all subsequent searches will be
---     skipped and the path will be used as-is.
function netinst.hooks.before(asked_name, found_path)
    netinst._utils.debug("before hook called for %s", asked_name)
    return nil
end

--- The default function that will be called after TeX searches for a file.
--- @type hook_function
--- @param asked_name string
---     The name of the file that TeX is looking for, as given in the TeX
---     source.
---
--- @param found_path string|nil
---     The name of the file that TeX found, or `nil` if it could not find the
---     file.
---
--- @return string|nil found_path
---     The name of the file that TeX should use, or `nil` if it could not be
---     found.
function netinst.hooks.after(asked_name, found_path)
    netinst._utils.debug(
        "after hook called for %s (found: %s)",
        asked_name, found_path or "(nil)"
    )
    return found_path
end

--- Runs a hook function.
--- @param asked_name string
---     The name of the file that TeX is looking for, as given in the TeX
---     source.
---
--- @param default hook_function
---     The default function called to look up this file.
---
--- @return string|nil found_path
---     The name of the file that TeX should use, or `nil` if it could not be
---     found.
local function run_hook(asked_name, default)
    local found_path = netinst.hooks.before(asked_name, nil)
    if found_path ~= nil then
        return found_path
    end

    found_path = default(asked_name)

    return netinst.hooks.after(asked_name, found_path)
end

--- A wrapper function for hooks, using an arbitrary function.
--- @param default hook_function
---     The default function called to look up this file.
---
--- @return fun(asked_name: string):(found_name: string|nil)
---     A function that takes the asked name and returns the found name.
local function hook_wrapper_function(default)
    return function(asked_name)
        return run_hook(asked_name, default)
    end
end

--- A wrapper function for hooks, using kpathsea.
--- @param file_type KpseFtype The file type to search for
--- @return fun(asked_name: string):(found_name: string|nil)
---     A function that takes the asked name and returns the found name.
local function hook_wrapper_kpse(file_type)
    local function default(asked_name)
        return kpse.find_file(asked_name, file_type, false)
    end
    return function(asked_name)
        return run_hook(asked_name, default)
    end
end


--------------------------
--- "Proper" Callbacks ---
--------------------------

-- A table holding the callback functions for the LuaTeX callbacks.
--- @type table<CallbackName, function>
local callbacks = {}

-- Let's do the "easy" callbacks first
callbacks.find_cidmap_file = hook_wrapper_kpse("cid maps")
callbacks.find_data_file = hook_wrapper_kpse("tex")
callbacks.find_enc_file = hook_wrapper_kpse("enc files")
callbacks.find_font_file = hook_wrapper_kpse("tfm")
callbacks.find_image_file = hook_wrapper_kpse("tex")
callbacks.find_map_file = hook_wrapper_kpse("map")
callbacks.find_opentype_file = hook_wrapper_kpse("opentype fonts")
callbacks.find_truetype_file = hook_wrapper_kpse("truetype fonts")
callbacks.find_type1_file = hook_wrapper_kpse("type1 fonts")
callbacks.find_vf_file = hook_wrapper_kpse("vf")
-- find_pk_file --> skipped, because this would be annoying to implement
-- find_format_file --> skipped, because this isn't used at runtime

-- Now for the more complex ones
function callbacks.find_read_file(id_number, asked_name)
    local function default(asked_name)
        return kpse.find_file(asked_name, "tex", false)
    end
    return run_hook(asked_name, default)
end

callbacks.find_font_file = hook_wrapper_function(function(asked_name)
    local extension = file.suffix(asked_name)
    local kpse_type = font_extension_to_kpse_type[extension]
    if not kpse_type then
        return nil
    end
    return kpse.find_file(asked_name, kpse_type, false)
end)

-- Now, let's register all the callbacks
for name, func in pairs(callbacks) do
    luatexbase.add_to_callback(
        name,
        func,
        ("%s.%s"):format(netinst._package_name, name)
    )
end


-------------------------
--- "Other" Callbacks ---
-------------------------

--- Overwrite the luaotfload font file finding callback function to use our own
--- resolver
--- comment
--- @param asked_name string
--- @return string|nil path
---     The path to the font file, or `nil` if it could not be found
---
--- @return nil - Always nil
--- @return boolean success Whether or not the search was successful.
--- @diagnostic disable-next-line: duplicate-set-field
function fonts.names.lookup_font_file(asked_name)
    local path = run_hook(
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

-- Add an additional Lua package searcher
insert(package.searchers, function(module_name)
    local path = run_hook(
        module_name .. ".lua",
        function(name) return nil end
    )
    if not path then
        return ("\n\tno TeX Live package found for %s"):format(module_name)
    end

    local func, err = loadfile(path)
    if not func then
        return ("\n\terror loading TeX Live package %s: %s"):format(
            module_name, tostring(err)
        )
    end

    return func
end)

--- Overwrite the internal expl3 \tex_filesize:D Lua-based command to look up
--- the file using our own resolvers so that \IfFileExists works correctly.
do
    local function tex_filesize_D()
        -- Scan the filename from TeX
        local filename = token.scan_string()

        -- Look up the file
        local path = run_hook(filename, function(name)
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

        -- Write the size back to TeX
        tex.sprint(string_catcodes, tostring(size))
    end

    local index = token.create("tex_filesize:D").mode
    lua.get_functions_table()[index] = tex_filesize_D
end
