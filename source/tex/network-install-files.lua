-- network-install
-- https://github.com/gucci-on-fleek/network-install
-- SPDX-License-Identifier: MPL-2.0+
-- SPDX-FileCopyrightText: 2026 Max Chernoff

--- This subpackage handles the file request hooks from TeX: it downloads files
--- from CTAN, saves them to the local filesystem, and returns the path to the
--- file for TeX to use.

----------------------
--- Initialization ---
----------------------

-- Make sure that the main package file is loaded first
if not netinst then
    require("network-install")
end
netinst._utils.debug("files subpackage loaded")


----------------------------
--- Function Definitions ---
----------------------------

--- Gets the absolute path to a file in the current directory, if it exists.
---
--- @param filename string The name of the file to look for
--- @return string? path
---     The absolute path to the file, or nil if it doesn't exist
local function get_from_current_directory(filename)
    local path = file.collapsepath(lfs.currentdir() .. "/" .. filename)
    if lfs.isfile(path) then
        return path
    else
        return nil
    end
end

--- Gets the local path to a file, downloading it from the network if necessary.
---
--- @param filename string
---     The name of the file to download, without any path components.
---
--- @return string? path
---     The absolute path to the file on the local filesystem, or `nil` if the
---     file could not be found or downloaded.
function netinst.get_file_from_somewhere(filename)
    local path --- @type string?
    netinst._utils.debug(
        "Requesting file: %s",
        filename
    )

    -- First, check if the file exists in the current directory. If it does,
    -- we'll always use that.
    path = get_from_current_directory(filename)
    if path then
        netinst._utils.debug(
            "Found file in current directory: %s",
            path
        )
        return path
    end

    -- Next, we'll look up the file in the database. If it's not in the
    -- database, then we'll just give up here
    local revision = netinst.get_latest_file_revision(filename)
    if not revision then
        netinst._utils.debug(
            "File not found in database: %s",
            filename
        )
        return nil
    end

    -- Now, we'll try getting it from the local cache.
    local exists
    exists, path = netinst.get_local_file_path(filename, revision)
    if exists then
        netinst._utils.debug(
            "Found file in cache: %s",
            path
        )
        return path
    end

    -- If it's not in the cache, we'll download it from the network.
    local data = netinst.download_from_database(filename)
    if data then
        netinst._utils.debug(
            "Downloaded file from network: %s (size: %d bytes)",
            filename, #data
        )
    else
        netinst._utils.debug(
            "Failed to download file from network: %s",
            filename
        )
        return nil
    end

    -- Save it to the cache for next time.
    local _, path = netinst.get_local_file_path(filename, revision)
    local ok = io.savedata(path, data)
    if ok then
        netinst._utils.debug(
            "Saved file to cache: %s",
            path
        )
    else
        netinst._utils.error("Failed to save file to cache: %s", path)
        return nil
    end

    return path
end

-------------
--- Hooks ---
-------------

-- Register `get_file_from_somewhere` as the before hook.
netinst.hooks.before = netinst.get_file_from_somewhere
