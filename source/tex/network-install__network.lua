-- texlive-auto-package-install
-- https://github.com/gucci-on-fleek/texlive-auto-package-install
-- SPDX-License-Identifier: MPL-2.0+
-- SPDX-FileCopyrightText: 2026 Max Chernoff

--- This subpackage contains the low-level network-related functions for the
--- package. Although LuaTeX has the built-in `socket` library, it doesn't
--- support HTTPS, which is required to securely download packages from CTAN.
--- Instead, we use the Lua FFI module to interface with the libcurl C library,
--- which provides robust support for HTTPS and support for persistent
--- connections, which can speed up multiple package downloads.
---
--- Note that this subpackage only contains the core code required to make HTTP
--- requests; the higher-level logic for downloading packages and handling errors
--- is in other subpackages.

----------------------
--- Initialization ---
----------------------

-- Make sure that the main package file is loaded first
assert(
    netinst._currently_loading_subpackages,
    "This file cannot be loaded directly."
)
netinst._utils.debug("network subpackage loaded")


-----------------
--- Constants ---
-----------------

local constants = netinst._curl_constants
local curl = netinst._curl
local ffi = require("ffi")
local insert = table.insert


---------------------------
--- Curl Initialization ---
---------------------------

-- Initialize libcurl itself
curl.curl_global_init(constants.CURL_GLOBAL_DEFAULT)
netinst._utils.cleanup(curl.curl_global_cleanup)

-- Initialize our global handle
--- @type userdata
local handle = curl.curl_easy_init()
netinst._utils.cleanup(curl.curl_easy_cleanup, handle)

if handle == nil then
    netinst._utils.error("Failed to initialize libcurl")
end
netinst._utils.debug("Initialized libcurl")

-- Get the libcurl version
local version_info = curl.curl_version_info(curl.CURLVERSION_FOURTH)
local version_string = ffi.string(version_info.version)
netinst._utils.debug("Using libcurl version %s", version_string)


--------------------
--- Curl Options ---
--------------------

--- Sets the options on a libcurl handle
---
--- @param handle userdata The libcurl handle to set options on
--- @param options table<string, boolean|integer|string|userdata>
---     A table of options to set, where the keys are the option names (without
---     the CURLOPT_ prefix) and the values are the option values.
--- @return nil
local function set_options(handle, options)
    for name, value in pairs(options) do
        -- Get the constant ID from the libcurl enum
        local option_constant = curl["CURLOPT_" .. name:upper()]
        if option_constant == nil then
            netinst._utils.error("Unknown libcurl option: " .. name)
        end

        -- Set the option
        local ok = curl.curl_easy_setopt(handle, option_constant, value)

        -- Check for errors
        if ok ~= curl.CURLE_OK then
            netinst._utils.error(
                "Failed to set libcurl option %s: %s",
                name, ffi.string(curl.curl_easy_strerror(ok))
            )
        else
            netinst._utils.debug(
                "Set libcurl option %s to %s", name, tostring(value)
            )
        end
    end
end

-- If debug mode is enabled, have libcurl print verbose output
--- @diagnostic disable-next-line: undefined-field
if _G.LOG_LEVEL == "debug" then
    set_options(handle, { verbose = true })
end

-- Set the default options for all requests
set_options(handle, {
    -- Fail if it takes more than 10 seconds to connect to the server
    connecttimeout = 10,

    -- Fail if the entire request takes more than 60 seconds
    timeout = 60,

    -- Fail the request if the server returns an HTTP error code
    failonerror = true,

    -- Don't download files larger than 100 MB
    maxfilesize = 100 * 1024^2,

    -- Only allow HTTPS
    protocols_str = "https",
    use_ssl = ffi.new("long", constants.CURLUSESSL_ALL),

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
netinst._utils.cleanup(curl.curl_share_cleanup, share_handle)

-- Configure the resource sharing options
for _, key in ipairs { "dns", "ssl_session", "connect" } do
    local share_constant = ffi.new(
        "long", curl["CURL_LOCK_DATA_" .. key:upper()]
    )
    local ok = curl.curl_share_setopt(
        share_handle, curl.CURLSHOPT_SHARE, share_constant
    )
    if ok ~= curl.CURLE_OK then
        netinst._utils.error(
            "Failed to set libcurl share option %s: %s",
            key, ffi.string(curl.curl_easy_strerror(ok))
        )
    else
        netinst._utils.debug("Set libcurl share option %s", key)
    end
end

set_options(handle, {
    share = share_handle,
})


---------------------------
--- Data write callback ---
---------------------------

-- Save the temporary data while processing the callbacks
--- @type table<string, string[]>
local callback_data = {
    header = {},
    body = {},
}

-- Using strings in ffi is annoying, so we'll use integer keys instead
local callback_keys = {
    [1] = "header",
    [2] = "body",
}

-- Define a C callback function using ffi
local write_callback = ffi.cast("void*", ffi.new(
    "write_callback",
    --- The function called by libcurl whenever it wants to write data
    --- @param contents userdata A pointer to a string containing the data
    --- @param size integer The size of each element in the contents string
    --- @param nmemb integer The number of elements in the contents string
    --- @param userdata userdata The user data specified when setting the callback
    --- @return integer real_size The number of bytes processed, or 0 to indicate an error
    function(contents, size, nmemb, userdata)
        -- Get the response data
        local real_size = size * nmemb
        local contents = ffi.string(contents, real_size)

        -- Store the data
        local callback_key = tonumber(ffi.cast("int", userdata))
        local data_table = callback_data[callback_keys[callback_key]]
        if type(data_table) ~= "table" then
            netinst._utils.error("Invalid userdata in write callback")
            return 0
        end
        insert(data_table, contents)

        -- Return the number of bytes processed
        return real_size
    end
))

-- Register the callbacks
set_options(handle, {
    writefunction  = write_callback,
    writedata      = ffi.new("int", table.swapped(callback_keys).body),
    headerfunction = write_callback,
    headerdata     = ffi.new("int", table.swapped(callback_keys).header),
})


------------------------
--- Public Functions ---
------------------------

--- @alias range [integer?, integer?]
---     [1]: The starting byte index of the range (inclusive)
---     [2]: The ending byte index of the range (inclusive)

--- Downloads the content of a URL and returns the response headers and body.
---
--- @param url string
---     The URL to download. This must include the protocol ("https://"); only
---     the HTTPS protocol is supported.
---
--- @param range? range
---     An optional range of bytes to download from the URL. If specified, only
---     the bytes in the range are downloaded.
---
--- @return table<string, string> headers A dictionary of the response headers
--- @return string data The response body
--- @return integer status_code The HTTP status code of the response
function netinst.get_url(url, range)
    -- Log the start of the request
    netinst._utils.debug("Starting request to %s", url)

    -- Clear previous data
    callback_data.header = {}
    callback_data.body = {}

    -- Copy the handle
    local request_handle = curl.curl_easy_duphandle(handle)
    set_options(request_handle, {
        url = url,
        share = share_handle,
    })

    -- Set the range if specified
    if range then
        local range_string
        if range[1] and range[2] then
            range_string = string.format("%d-%d", range[1], range[2])
        elseif range[1] and (not range[2]) then
            range_string = string.format("%d-", range[1])
        elseif (not range[1]) and range[2] then
            range_string = string.format("-%d", range[2])
        else
            netinst._utils.error("Invalid range: both start and end are nil")
        end
        set_options(request_handle, { range = range_string })
    end

    -- Make the request
    local ok = curl.curl_easy_perform(request_handle)
    if ok ~= curl.CURLE_OK then
        pcall(curl.curl_easy_cleanup, request_handle)
        request_handle = nil
        netinst._utils.error(
            "Failed to perform libcurl request: %s",
            ffi.string(curl.curl_easy_strerror(ok))
        )
    else
        netinst._utils.debug("Request to %s completed successfully", url)
    end

    -- Get the response data
    local header_data = table.concat(callback_data.header)
    local body_data = table.concat(callback_data.body)

    -- Get the HTTP status code
    local status_code_ptr = ffi.new("long[1]", 0)
    local ok = curl.curl_easy_getinfo(
        request_handle, curl.CURLINFO_RESPONSE_CODE, status_code_ptr
    )

    -- Free the request handle right away since we don't need it anymore
    pcall(curl.curl_easy_cleanup, request_handle)
    request_handle = nil

    -- Check the status code
    local status_code --- @type integer
    if ok ~= curl.CURLE_OK then
        netinst._utils.error(
            "Failed to get HTTP status code from libcurl response: %s",
            ffi.string(curl.curl_easy_strerror(ok))
        )
    else
        status_code = tonumber(status_code_ptr[0]) --[[@as integer]]
        netinst._utils.debug(
            "Received HTTP status code %d from %s",
            status_code, url
        )
    end

    if status_code <= 0 or status_code >= 1000 then
        netinst._utils.error(
            "Received invalid HTTP status code %d from %s",
            status_code, url
        )
    end

    -- Process the response headers
    local headers = {}
    for _, line in ipairs(header_data:split("\r\n") or {}) do
        local key, value = line:match("^(.-):%s*(.-)%s*$")
        if key and value then
            headers[key:lower()] = value
        end
    end

    -- Make sure that the range request was successful
    if range then
        local content_range = headers["content-range"] or ""
        local start_byte, stop_byte = content_range:match("^bytes (%d+)%-(%d+)/")
        start_byte, stop_byte = tonumber(start_byte), tonumber(stop_byte)

        if  ((not range[1]) or (start_byte == range[1])) and
            ((not range[2]) or (stop_byte  == range[2]))
        then
            netinst._utils.debug(
                "Received expected byte range: %s", content_range
            )
        else
            netinst._utils.error(
                "Received unexpected byte range: %s (requested %d-%d)",
                content_range or "(nil)",
                range[1] or 0, range[2] or math.huge
            )
        end
    end

    return headers, body_data, status_code
end
