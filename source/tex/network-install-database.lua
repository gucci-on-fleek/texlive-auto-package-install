-- texlive-auto-package-install
-- https://github.com/gucci-on-fleek/texlive-auto-package-install
-- SPDX-License-Identifier: MPL-2.0+
-- SPDX-FileCopyrightText: 2026 Max Chernoff

--- This subpackage handles the database matching filenames to a network location
--- for installation. It automatically refreshes the database if it's
--- out-of-date, and handles selecting the correct revision for each file.

----------------------
--- Initialization ---
----------------------

-- Make sure that the main package file is loaded first
if not netinst then
    require("network-install")
end
netinst._utils.debug("database subpackage loaded")


-----------------
--- Constants ---
-----------------

local remote_database_path = "network-install.files.lut.gz"
local zip_file_path = "network-install.files.zip"
local days_to_seconds = 24 * 60 * 60
local zip_window_bits = -15

--- lualibs overwrites the original `load` function, but it saves it as
--- `loadstring`, so we'll just use that directly. But then LuaLS doesn't like
--- this, so we need to add these annoying type annotations to make it work.
--- @type fun(chunk: string, chunkname?: string, mode?: string, env?: table): function
--- @diagnostic disable-next-line: deprecated
local load = loadstring

------------------------
--- Database Parsing ---
------------------------

--- @class (exact) database_entry
--- @field source   string The source of the file (as a constant)
--- @field path     string The path to the file in this source
--- @field revision integer The SVN revision of the file

--- @class (exact) database_entry.ctan: database_entry
--- @field source   "ctan" The source of the file

--- @class (exact) database_entry.zip: database_entry
--- @field source   "zip" The source of the file
--- @field offset   range
---     The byte offset of the file in the ZIP archive

--- @alias database table<string, database_entry>

local allowed_functions = {
    -- Needed so that we can remove the hook after we've finished running the
    -- chunk. We never give access to this function to the chunk, so it _should_
    -- be safe to allow it here.
    [debug.sethook] = true,

    -- We run the function inside pcall so that the errors don't propagate, so
    -- we also need to allow this here. This is always safe to allow.
    [pcall] = true,

    -- We will also dynamically add the loaded chunk to this table while we run
    -- it.
}

--- A debug hook that denies all function calls.
---
--- @param event "call" | "return" | "line" | "count" | "tail call"
---     The type of the event that triggered the hook.
---
--- @param line? integer
---     The current line of code being executed, if the event is "line".
---
--- @return nil
local function deny_all_functions(event, line)
    if event == "call" or event == "tail call" then
        local info = debug.getinfo(2, "fn")
        local func = info.func
        local name = info.name
        if not allowed_functions[func] then
            error("Forbidden function call: " .. (name or "<unknown>"))
        end
    end
end

--- Parses the raw data of the database file into a Lua table.
---
--- @param data string The (uncompressed) raw data of the database file
--- @return database database The parsed database
local function parse_database(data)
    if type(data) ~= "string" then
        netinst._utils.error("Invalid database data: expected a string.")
    end

    -- SECURITY: The database file is just a plain Lua file, so we need to be
    -- careful when loading it to not execute any malicious code. We will use
    -- the following techniques:
    --
    -- 1. Only allow loading text files, not bytecode files. The Lua interpreter
    --    is only safe to use on untrusted text files, whereas bytecode files
    --    easily bypass most restrictions.
    --
    -- 2. Limit the environment of the loaded file to an empty table, so that it
    --    cannot access any functions or variables from the main environment.
    --    This prevents the file from doing anything malicious, such as reading
    --    or writing files, making network requests, or executing arbitrary
    --    code.
    --
    -- 3. Use a debug hook to prevent the loaded file from accessing any
    --    metamethods on type "string" type. The default Lua string functions
    --    are all safe, but some of the LuaLaTeX/ConTeXt additions aren't, so
    --    we'll just unconditionally block all function calls to be safe.

    -- Load the file with the restricted environment
    local chunk, err = load(data, "database", "t", {})
    if not chunk then
        netinst._utils.error("Failed to load database: %s", err)
    end

    -- Run the chunk with the debug hook to prevent malicious behavior
    allowed_functions[chunk] = true
    debug.sethook(deny_all_functions, "c")
    local ok, result = pcall(chunk)
    debug.sethook()
    allowed_functions[chunk] = nil

    -- Check the result
    if not ok then
        netinst._utils.error("Failed to execute database: %s", result)
    end
    if type(result) ~= "table" then
        netinst._utils.error("Invalid database format: expected a table.")
    end

    return result
end


------------------------
--- Database Loading ---
------------------------

--- The main database mapping filenames to their sources and paths.
--- @type database
local database do
    local database_path, last_modified = netinst.get_local_database_path()
    local yesterday = os.time() - days_to_seconds

    -- If the database file is less than 1 day old, use the cached version.
    if last_modified >= yesterday then
        netinst._utils.debug(
            "Using cached database (last modified: %s)",
            os.date("%Y-%m-%d %H:%M:%S", last_modified)
        )
        local data = io.loaddata(database_path)
        if not data then
            netinst._utils.error("Failed to read database file: %s", database_path)
        end
        database = parse_database(data)

    -- Otherwise, download it from the network and save it to the cache for next
    -- time.
    else
        -- Download the database from the network
        netinst._utils.debug("Cached database is out of date, refreshing...")
        local data = netinst._get_metafile(remote_database_path)
        if not data then
            netinst._utils.error(
                "Failed to download database from network: %s",
                remote_database_path
            )
        end

        -- Decompress it
        data = gzip.decompress(data)

        if (type(data) ~= "string") or (data == "") then
            netinst._utils.error("Failed to decompress database: invalid data.")
        end

        -- Parse it
        database = parse_database(data)

        -- Save it to the cache for next time
        if io.savedata(database_path, data) then
            netinst._utils.debug(
                "Saved refreshed database to cache: %s",
                database_path
            )
        else
            netinst._utils.error(
                "Failed to save database to cache: %s",
                database_path
            )
        end
    end
end


---------------------
--- File Handling ---
---------------------

--- Gets the latest revision number of a file in the database.
---
--- @param filename string
---     The name of the file to check, without any path components.
---
--- @return integer|nil revision
---     The latest revision number of the file in the database, or `nil` if the
---     file is not found in the database.
function netinst.get_latest_file_revision(filename)
    local entry = database[filename]
    if not entry then
        return nil
    end
    return entry.revision
end

--- Downloads and extracts a file from a .zip archive.
---
--- @param offset range The byte offset of the file in the ZIP archive.
--- @return string data The decompressed contents of the file.
local function download_from_zip(offset)
    netinst._utils.debug(
        "Downloading file from ZIP archive at offset %d-%d.",
        offset[1], offset[2]
    )

    -- Download the range of bytes from the zip file
    local compressed = netinst._get_metafile(zip_file_path, offset)

    -- Decompress the downloaded range
    local data = zlib.decompress(compressed, zip_window_bits)
    if not data then
        netinst._utils.error(
            "Failed to decompress file from ZIP archive at offset %d.",
            offset
        )
    end
    return data
end

--- Downloads the latest version of a file from CTAN, using the path from the
--- database.
---
--- @param filename string
---     The name of the file to download, without any path components.
---
--- @return string data The contents of the file.
function netinst.download_from_database(filename)
    -- Verify that the file exists
    local entry = database[filename]
    if not entry then
        netinst._utils.error(
            "File not found in database: %s",
            filename
        )
    end

    -- If the file is available unpacked on CTAN, we can just download it
    -- directly.
    if entry.source == "ctan" then
        --- @cast entry database_entry.ctan
        return netinst.ctan_get(entry.path)

    -- Otherwise, we'll need to extract it from the .zip archive.
    elseif entry.source == "zip" then
        --- @cast entry database_entry.zip
        return download_from_zip(entry.offset)
    else
        netinst._utils.error(
            "Invalid source for file %s: %s",
            filename, entry.source
        )
    end
end
