-- texlive-auto-package-install
-- https://github.com/gucci-on-fleek/texlive-auto-package-install
-- SPDX-License-Identifier: MPL-2.0+
-- SPDX-FileCopyrightText: 2026 Max Chernoff

--- This subpackage contains the code for handling the low-level filesystem
--- operations, such as accessing files in the local cache. The higher-level
--- logic for downloading packages and handling errors is in other subpackages.

----------------------
--- Initialization ---
----------------------

-- Make sure that the main package file is loaded first
assert(
    netinst._currently_loading_subpackages,
    "This file cannot be loaded directly."
)
netinst._utils.debug("filesystem subpackage loaded")


-----------------
--- Constants ---
-----------------

local database_filename = "network-install.files.lut"
local ctan_mirror_filename = "network-install.ctan_mirror.txt"
local local_file_template = string.formatters["%s/%s.%06i"]
local item_separator = netinst._utils.os_case {
    windows = ";",
    default = ":"
}


---------------------
--- Path Handling ---
---------------------

--- The root directory for the package cache location
--- @type string
local cache_root do
    -- Get a list of absolute paths to the TeX cache directories from kpathsea
    local caches = kpse.expand_path("$TEXMFCACHE"):split(item_separator)

    -- Choose the first acceptable cache directory
    for _, cache in ipairs(caches) do
        -- Make sure that we're allowed to write to this cache directory
        if not kpse.out_name_ok_silent_extended(cache) then
            goto continue
        end
        if not file.is_writable(cache) then
            goto continue
        end

        -- Make sure that the cache directory exists
        local cache_path = ("%s/%s"):format(cache, netinst._utils.pkg_name)
        local ok, msg = lfs.mkdirp(cache_path)

        if ok or (msg == "File exists") then
            cache_root = cache_path
            break
        else
            goto continue
        end

        ::continue::
    end

    if cache_root then
        netinst._utils.debug(
            "Using cache directory: %s",
            cache_root
        )
    else
        netinst._utils.error(
            "No suitable cache directory found. Please make sure that you have a writable cache directory configured in TeX Live."
        )
    end
end

--- Gets the path to a local file in the cache.
---
--- @param filename string
---     The name of the file to get, without any path components. This must not
---     contain a "/" character.
---
--- @param revision integer The SVN revision number of the file to get.
--- @return boolean exists Whether the file exists in the cache.
--- @return string  path
---     The path to the file in the cache, or the path where the file would be
---     stored *if* it existed in the cache.
---
function netinst.get_local_file_path(filename, revision)
    if filename:find("/") then
        netinst._utils.error(
            "Invalid filename: %s. Filenames must not contain path components.",
            filename
        )
    end

    local path = local_file_template(cache_root, filename, revision)
    if io.exists(path) then
        return true, path
    else
        return false, path
    end
end

--- Gets the path to the local database file in the cache.
---
--- @return string path
---     The path to the local database file in the cache, regardless of whether
---     it exists or not.
---
--- @return integer last_modified
---     The last modified time of the local database file as a Unix timestamp
---     in seconds, or 0 if the file does not exist.
---
function netinst.get_local_database_path()
    local path = ("%s/%s"):format(cache_root, database_filename)
    if io.exists(path) then
        local modified = lfs.attributes(path, "modification") --[[@as integer]]
        if not modified then
            netinst._utils.error(
                "Failed to get last modified time for local database file: %s",
                path
            )
        end
        return path, modified
    else
        return path, 0
    end
end

--- Gets the path to the CTAN mirror file. (Private)
---
--- @return string path The path to the CTAN mirror file.
--- @return boolean exists Whether the CTAN mirror file exists.
function netinst._get_ctan_mirror_file_path()
    local path = ("%s/%s"):format(cache_root, ctan_mirror_filename)
    return path, io.exists(path)
end
