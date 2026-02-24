-- network-install
-- https://github.com/gucci-on-fleek/network-install
-- SPDX-License-Identifier: MPL-2.0+
-- SPDX-FileCopyrightText: 2026 Max Chernoff

--- This subpackage loads the required C-based shared objects/dynamic libraries
--- using the Lua FFI module. These libraries are then used by the other
--- subpackages.
---
--- Since the Lua FFI module is not available on all platforms, eventually
--- this subpackage will (probably) be rewritten in C and statically linked
--- into the LuaTeX engine executable.

----------------------
--- Initialization ---
----------------------

-- Make sure that the main package file is loaded first
assert(
    netinst._currently_loading_subpackages,
    "This file cannot be loaded directly."
)
netinst._utils.debug("ffi subpackage loaded")


-----------------
--- Constants ---
-----------------

local shell_escape_settings = {
    disabled = 0,
    unrestricted = 1,
    restricted = 2,
}


-----------
--- FFI ---
-----------

-- Try to load ffi
local ok, ffi = pcall(require, "ffi")

-- Uh oh, ffi doesn't work. Let's see what's wrong.
if not ok then
    -- See if shell escape is enabled
    local shell_escape = status.shell_escape
    if shell_escape ~= shell_escape_settings.unrestricted then
        netinst._utils.error("Shell escape must be enabled")

    -- If shell escape is enabled but we can't load the ffi module, then we're
    -- probably using an unsupported platform.
    else
        netinst._utils.error("Platform does not support Lua FFI module")
    end
end
netinst._utils.debug("FFI loaded")


------------
--- Curl ---
------------

-- Load the libcurl shared library.
local curl_name = netinst._utils.os_case {
    linux   = "libcurl.so.4",
    mac     = "libcurl.dylib.4",
    windows = "libcurl.dll",
}
local ok, curl = pcall(ffi.load, curl_name)

if not ok then
    -- Ok, try loading our own copy of libcurl.
    local curl_path = kpse.find_file(curl_name, "texmfscripts")
    if curl_path then
        local ok
        ok, curl = pcall(ffi.load, curl_path)
        if not ok then
            curl = nil
        end
    end
end

if curl then
    netinst._utils.debug(
        "Successfully loaded libcurl: %s",
        curl_name
    )
else
    netinst._utils.error(
        "Failed to load libcurl. Searched for: %s",
        curl_name
    )
end

-- Search for the header file
local header_path = kpse.find_file(netinst._utils.pkg_name .. "__curl.h")
local header_data = io.loaddata(header_path)
if not header_data then
    netinst._utils.error("Failed to load libcurl header file")
end

-- Load the header file
ffi.cdef(header_data)
netinst._utils.debug("curl headers loaded")

-- Define the Curl constants. These would normally be defined in the header
-- file, but the ffi module doesn't support "long" constants.
local curl_constants = {
    CURL_GLOBAL_DEFAULT = 0x03,
    CURLUSESSL_ALL = 0x03,
}

-- Export the curl library
netinst._curl = curl
netinst._curl_constants = curl_constants
