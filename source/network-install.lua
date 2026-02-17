-- texlive-auto-package-install
-- https://github.com/gucci-on-fleek/texlive-auto-package-install
-- SPDX-License-Identifier: MPL-2.0+
-- SPDX-FileCopyrightText: 2026 Max Chernoff

----------------------
--- Initialization ---
----------------------

-- The package name
local pkg_name = "network-install"

-- Log the package loading to the console
luatexbase.provides_module {
    name = pkg_name,
    date = "2026/01/21", --%%slashdate
    version = "0.1.2", --%%version
    description = "Automatically installs missing LaTeX packages from TeX Live",
}

-- Define the global table for the package
netinst = netinst or {} --- @diagnostic disable-line: global-element

-- The module log level
--- @type log_level
--- @diagnostic disable-next-line: undefined-field
local LOG_LEVEL = _G.LOG_LEVEL or "info"


-----------------
--- Constants ---
-----------------

local io_stderr = io.stderr
local debug_prefix = ("\x1b[0;36m[%s] "):format(pkg_name)
local debug_suffix = "\x1b[0m\n"


-----------------------------------------
--- General-purpose Utility Functions ---
-----------------------------------------

-- Private table for utility functions used by other subpackages
netinst._utils = {}

-- The message levels
--- @alias log_level "debug" | "info" | "warning" | "error"
--- @type table<log_level, integer>
local log_level_integers = {
    debug = 1,
    info = 2,
    warning = 3,
    error = 4,
}

-- Message printers by log level
--- @type table<log_level, fun(message: string)>
local message_printers = {
    debug = function(message)
        if LOG_LEVEL == "debug" then
            -- Write to the console
            io_stderr:write(debug_prefix, message, debug_suffix)

            -- Also write to the log file
            texio.write_nl("log", "[auto-package-install] " .. message)
        end
    end,
    info = function(message)
        luatexbase.module_info(pkg_name, message)
    end,
    warning = function(message)
        luatexbase.module_warning(pkg_name, message)
    end,
    error = function(message)
        luatexbase.module_error(pkg_name, message)
    end,
}

--- Converts an arbitrary message to a string
--- @param message string|any The message to convert
--- @param ... any Additional arguments to format the message with
--- @return string
local function format_message(message, ...)
    -- If the first argument is a format string, then use it.
    if type(message) == "string" and message:match("%%") then
        return message:format(...)
    end

    -- Otherwise, format the message ourselves.
    local data
    if select("#", ...) == 0 then
        if type(message) ~= "table" then
            return tostring(message)
        end
    else
        data = { message, ... }
    end

    -- Format
    message = table.serialize(
        data, false, { noquotes = true }
    ):gsub("\n( +)", "\n%1%1%1%1")

    return message
end

--- Define a message function wrapper that checks the log level before printing
--- @param level log_level
--- @return fun(message: string, ...: any)
local function message_wrapper(level)
    local wrapped_log_level = log_level_integers[level]
    local wrapped_message_printer = message_printers[level]
    if (not wrapped_log_level) or (not wrapped_message_printer) then
        error("Invalid log level: " .. tostring(level))
    end

    --- Prints a message at the specified log level
    --- @param message string|any The message to print
    --- @param ... any Additional arguments to format the message with
    --- @return nil
    return function(message, ...)
        -- Check to see if the message should be printed based on the log level
        if wrapped_log_level < log_level_integers[LOG_LEVEL] then
            return
        end

        -- Format the message
        message = format_message(message, ...)

        -- Call the appropriate printer
        wrapped_message_printer(message)
    end
end

-- Define the message functions
netinst._utils.debug = message_wrapper("debug")
netinst._utils.info = message_wrapper("info")
netinst._utils.warning = message_wrapper("warning")
netinst._utils.error = message_wrapper("error")


-------------------
--- Subpackages ---
-------------------

-- Set a flag to indicate that we're loading the subpackages
netinst._currently_loading_subpackage = true

-- Load the subpackages
require(pkg_name .. "__network")
require(pkg_name .. "__filesystem")
require(pkg_name .. "__tex")

-- Clear the flag
netinst._currently_loading_subpackage = nil

-- Return the exports
return netinst
