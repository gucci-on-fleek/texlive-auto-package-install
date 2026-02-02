-- texlive-auto-package-install
-- https://github.com/gucci-on-fleek/texlive-auto-package-install
-- SPDX-License-Identifier: MPL-2.0+
-- SPDX-FileCopyrightText: 2026 Max Chernoff

----------------------
--- Initialization ---
----------------------

local exports = {}

-- Constants
local DEBUG = _G.DEBUG or false --- @diagnostic disable-line: undefined-field
local pkg_name = "auto-package-install"
local io_stderr = io.stderr
local debug_prefix = "\x1b[0;36m[auto-package-install] "
local debug_suffix = "\x1b[0m\n"
local insert = table.insert
local unpack = table.unpack

local shell_escape_settings = {
    disabled = 0,
    unrestricted = 1,
    restricted = 2,
}

-----------------------------------------
--- General-purpose Utility Functions ---
-----------------------------------------

--- Prints a debug message if debugging is enabled
--- @param ... any The values to print
--- @return nil
local function debug(...)
    if DEBUG then
        local first = select(1, ...)
        if type(first) == "string" and first:match("%%") then
            io_stderr:write(
                debug_prefix ..
                first:format(select(2, ...)) ..
                debug_suffix
        )
        else
            io_stderr:write(debug_prefix, ...)
            io_stderr:write(debug_suffix)
        end
    end
end

--- Raise a TeX error from Lua
--- @param message string The error message
--- @return nil
local function tex_error(message)
    luatexbase.module_error(pkg_name, message)
end

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
        error("Shell escape must be enabled")
    else
        error("Platform does not support Lua FFI module")
    end
end

-- Now let's load the libcurl shared library
local so_name
if os.type == "windows" then
    so_name = "libcurl.dll"
elseif os.name == "macosx" then
    so_name = "libcurl.dylib.4"
else
    so_name = "libcurl.so.4"
end

local curl = ffi.load(so_name)
debug("Loaded libcurl from %s", so_name)

-- Define the libcurl functions and constants we need
local header_path = kpse.find_file("auto-package-install-curl.h")
local header_data = io.loaddata(header_path)
ffi.cdef(header_data)

local CURLUSESSL_ALL = 0x03
local CURL_GLOBAL_DEFAULT = 0x03

debug("Defined libcurl functions and constants")



---------------------------
--- Curl Initialization ---
---------------------------

-- Functions to run on exit
local cleanup_functions = {}
luatexbase.add_to_callback("wrapup_run", function()
    for _, func in ipairs(cleanup_functions) do
        pcall(func)
    end
    debug("Cleaned up libcurl")
end, pkg_name .. ".cleanup_curl")

-- Initialize the curl library
curl.curl_global_init(CURL_GLOBAL_DEFAULT)
insert(cleanup_functions, curl.curl_global_cleanup)

local handle = curl.curl_easy_init()
insert(cleanup_functions, function()
    curl.curl_easy_cleanup(handle)
end)

if handle == nil then
    tex_error("Failed to initialize libcurl")
    return -- (unreachable)
end
debug("Initialized libcurl")

-- Get the libcurl version
local version_info = curl.curl_version_info(curl.CURLVERSION_FOURTH)
local version_string = ffi.string(version_info.version)
debug("Using libcurl version %s", version_string)

-- Set the curl options
local function set_options(handle, options)
    for name, value in pairs(options) do
        local option_constant = curl["CURLOPT_" .. name:upper()]
        if option_constant == nil then
            tex_error("Unknown libcurl option: " .. name)
        else
            local res = curl.curl_easy_setopt(handle, option_constant, value)
            if res ~= curl.CURLE_OK then
                tex_error("Failed to set libcurl option " .. name .. ": " .. ffi.string(curl.curl_easy_strerror(res)))
            else
                debug("Set libcurl option %s to %s", name, tostring(value))
            end
        end
    end
end

if DEBUG then
    set_options(handle, { verbose = true })
end

set_options(handle, {
    -- Fail if it takes more than 10 seconds to connect to the server
    connecttimeout = 10,

    -- Fail if the entire request takes more than 30 seconds
    timeout = 60,

    -- Fail the request if the server returns an HTTP error code
    failonerror = true,

    -- Don't download files larger than 100 MB
    maxfilesize = 100 * 1024^2,

    -- Only allow HTTPS
    protocols_str = "https",
    use_ssl = ffi.new("long", CURLUSESSL_ALL),

    -- Enable TCP keepalive
    tcp_keepalive = true,

    -- Set a custom user agent
    useragent = "texlive-auto-package-install/0.1.2 (+https://github.com/gucci-on-fleek/texlive-auto-package-install)", --%%version

    -- Increase the buffer size to the maximum allowed by libcurl
    buffersize = 512 * 1000,

    -- Don't follow redirects
    followlocation = ffi.new("long", false),
    maxredirs = 0,
})

-- Initialize resource sharing
local share_handle = curl.curl_share_init()
insert(cleanup_functions, function()
    curl.curl_share_cleanup(share_handle)
end)

for _, key in ipairs { "dns", "ssl_session", "connect" } do
    local share_constant = ffi.new("long", curl["CURL_LOCK_DATA_" .. key:upper()])
    local res = curl.curl_share_setopt(share_handle, curl.CURLSHOPT_SHARE, share_constant)
    if res ~= curl.CURLE_OK then
        tex_error("Failed to set libcurl share option " .. key .. ": " .. ffi.string(curl.curl_easy_strerror(res)))
    else
        debug("Set libcurl share option %s", key)
    end
end

set_options(handle, {
    share = share_handle,
})

---------------------------
--- Data write callback ---
---------------------------

local callback_data = {
    header = {},
    body = {},
}
local callback_keys = {
    [1] = "header",
    [2] = "body",
}

local write_callback = ffi.cast("void*", ffi.new(
    "write_callback",
    function(contents, size, nmemb, userdata)
        -- Get the response data
        local real_size = size * nmemb
        local contents = ffi.string(contents, real_size)

        -- Store the data
        local callback_key = tonumber(ffi.cast("int", userdata))
        local data_table = callback_data[callback_keys[callback_key]]
        if type(data_table) ~= "table" then
            tex_error("Invalid userdata in write callback")
            return 0
        end
        insert(data_table, contents)

        -- Return the number of bytes processed
        return real_size
    end
))

set_options(handle, {
    writefunction = write_callback,
    writedata = ffi.new("int", table.swapped(callback_keys).body), --- @diagnostic disable-line: undefined-field
    headerfunction = write_callback,
    headerdata = ffi.new("int", table.swapped(callback_keys).header), --- @diagnostic disable-line: undefined-field
})

---------------
--- Request ---
---------------

local function get_url(url)
    -- Clear previous data
    callback_data.header = {}
    callback_data.body = {}

    -- Copy the handle
    local request_handle = curl.curl_easy_duphandle(handle)
    set_options(request_handle, {
        url = url,
        share = share_handle,
    })

    -- Make the request
    local ok = curl.curl_easy_perform(request_handle)
    pcall(curl.curl_easy_cleanup, request_handle)
    if ok ~= curl.CURLE_OK then
        tex_error("Failed to perform libcurl request: " .. ffi.string(curl.curl_easy_strerror(ok)))
        return -- (unreachable)
    else
        debug("Performed libcurl request successfully")
    end

    -- Get the response data
    local header_data = table.concat(callback_data.header)
    local body_data = table.concat(callback_data.body)

    -- Process the response headers
    local headers = {}
    for _, line in ipairs(header_data:split("\r\n") or {}) do
        local key, value = line:match("^(.-):%s*(.-)%s*$")
        if key and value then
            headers[key:lower()] = value
        end
    end

    return headers, body_data
end

---------------
--- Testing ---
---------------

inspect {
    get_url("https://www.maxchernoff.ca/"),
}

--------------------
--- Finalization ---
--------------------

return exports
