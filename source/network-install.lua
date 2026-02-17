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
local LOG_LEVEL = _G.LOG_LEVEL or "warning"

-- Private table for utility functions used by other subpackages
netinst._utils = {}
netinst._utils.pkg_name = pkg_name


-----------------
--- Constants ---
-----------------

local debug_prefix = "\x1b[0;36m"
local debug_suffix = "\x1b[0m\n"
local insert = table.insert
local io_stderr = io.stderr
local start_time = os.gettimeofday()


------------------------
--- Message Printing ---
------------------------

-- The message levels
--- @alias log_level "debug" | "warning" | "error"
--- @type table<log_level, integer>
local log_level_integers = {
    debug = 1,
    -- info = 2, (ignored)
    warning = 3,
    error = 4,
}

-- Message printers by log level
--- @type table<log_level, fun(message: string)>
local message_printers = {
    debug = function(message)
        if LOG_LEVEL == "debug" then
            -- Format the message with a timestamp and package name
            message = ("[%s %7.3f] %s"):format(
                pkg_name,
                os.gettimeofday() - start_time,
                message

            )
            -- Write to the console
            io_stderr:write(debug_prefix, message, debug_suffix)

            -- Also write to the log file
            texio.write_nl("log", message)
        end
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
netinst._utils.warning = message_wrapper("warning")
netinst._utils.error = message_wrapper("error")


-------------------------
--- Utility Functions ---
-------------------------

--- @alias operating_system "windows" | "linux" | "mac" | "other"
--- @type operating_system
local os_name
if os.name == "windows" then
    os_name = "windows"
elseif os.name == "linux" then
    os_name = "linux"
elseif os.name == "macosx" then
    os_name = "mac"
else
    os_name = "other"
end
netinst._utils.debug("Detected operating system: %s", os_name)

--- A function that returns a value based on the current operating system
--- @generic T
---
--- @param cases table<operating_system | "default", `T`>
---     A table mapping operating systems to values. The "default" key is used
---     if the current operating system doesn't match any of the provided cases.
---
--- @return T
---     The value corresponding to the current operating system, or the
---     default value if no match is found.
function netinst._utils.os_case(cases)
    local value = cases[os_name]
    if value == nil then
        value = cases.default
    end
    if value == nil then
        netinst._utils.error('\z
            (Internal Error) No case for operating system "%s" and no \z
            default case provided.\z
        ', os_name)
    end
    return value
end

--- A list of functions to run on exit
--- @type fun()[]
local cleanup_functions = {}

--- A function to register a cleanup function to be run on exit
--- @generic T
--- @param func fun(T) The function to run on exit
--- @param arg? `T` An optional argument to pass to the function
--- @return nil
function netinst._utils.cleanup(func, arg)
    if arg ~= nil then
        insert(cleanup_functions, function()
            func(arg)
        end)
    else
        insert(cleanup_functions, func)
    end
end

-- Register the callback
luatexbase.add_to_callback("wrapup_run", function()
    for _, func in ipairs(cleanup_functions) do
        pcall(func)
    end
    netinst._utils.debug("Cleanup finished")
end, netinst._utils.pkg_name .. ".cleanup")


-------------------
--- Subpackages ---
-------------------

-- Set a flag to indicate that we're loading the subpackages
netinst._currently_loading_subpackages = true

-- Load the subpackages
require(pkg_name .. "__ffi")
require(pkg_name .. "__network")
require(pkg_name .. "__filesystem")
require(pkg_name .. "__hooks")

-- Clear the flag
netinst._currently_loading_subpackages = nil

-- Return the exports
netinst._utils.debug("Loading complete")
return netinst
