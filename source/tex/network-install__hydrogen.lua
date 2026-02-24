-- network-install
-- https://github.com/gucci-on-fleek/network-install
-- SPDX-License-Identifier: MPL-2.0+
-- SPDX-FileCopyrightText: 2026 Max Chernoff

--- This subpackage loads libhydrogen, which is used by the other subpackages to
--- validate the database signature.

----------------------
--- Initialization ---
----------------------

-- Make sure that the main package file is loaded first
assert(
    netinst._currently_loading_subpackages,
    "This file cannot be loaded directly."
)
netinst._utils.debug("hydrogen subpackage loaded")


--------------------------
--- Platform Detection ---
--------------------------

-- The platform detection code needs to be a bit more complicated than just
-- checking "os.name", because we also care about the architecture and libc.
-- LuaLaTeX provides "os.platform" (via ConTeXt), but this uses ConTeXt's weird
-- naming conventions which don't match the ones used by TeX Live. So, we'll do
-- things ourselves here.

local platform do
    -- Get the folder where this copy of LuaTeX is located. We need this to
    -- handle some special cases.
    local platform_path = file.basename(os.selfdir)

    -- Get the libc. Empty in most cases
    local libc = platform_path:match("legacy$") or
                 platform_path:match("musl$")   or
                 ""

    -- Get the OS name. This is the easy step.
    local name = os.name

    -- TeX Live uses "darwin" for macOS.
    if name == "macosx" then
        name = "darwin"
    end

    -- Hmm, the LuaTeX source doesn't list NetBSD as an option for "os.name",
    -- but it definitely exists. Let's check for it manually.
    if os.uname().sysname:lower() == "netbsd" then
        name = "netbsd"
    end

    -- Get the architecture. This is trickier.
    local architecture = os.uname().machine

    -- TeX Live uses "i386" for all 32-bit x86 architectures.
    if  architecture == "i686" or
        architecture == "i586" or
        architecture == "i386"
    then
        architecture = "i386"
    end

    -- TeX Live uses "x86_64" for all 64-bit x86 on Linux and macOS, and "amd64"
    -- on BSDs.
    if (architecture == "x86_64") or (architecture == "amd64") then
        if (name == "darwin") or (name == "linux") then
            architecture = "x86_64"
        elseif name:match("bsd$") then
            architecture = "amd64"
        else
            -- Leave everything else unchanged.
        end
    end

    -- Non-legacy macOS uses universal binaries.
    if name == "darwin" and libc == "" then
        architecture = "universal"
    end

    -- Windows doesn't use an architecture at all.
    if name == "windows" then
        architecture = ""
    end

    -- Finally, we can assemble the platform string.
    platform = table.concat {
        architecture,
        architecture ~= "" and "-" or "",
        name,
        libc,
    }
end


---------------
--- Loading ---
---------------

do
    -- Get the full path to the libhydrogen shared library
    local lib_name = ("libhydrogen.%s.%s"):format(platform, os.libsuffix)
    local lib_path = kpse.find_file(lib_name, "texmfscripts")

    if lib_path then
        netinst._utils.debug(
            "Found libhydrogen at path: %s",
            lib_path
        )
    else
        netinst._utils.error(
            "Failed to find libhydrogen. Searched for: %s",
            lib_name
        )
    end

    -- Load the library
    local c_loader = package.loadlib(lib_path, "luaopen_hydrogen")
    if c_loader then
        netinst._utils.debug(
            "Successfully loaded libhydrogen from path: %s",
            lib_path
        )
    else
        netinst._utils.error(
            "Failed to load libhydrogen from path: %s",
            lib_path
        )
    end

    -- Initialize the library
    local success, libhydrogen = pcall(c_loader)
    if success then
        netinst._utils.debug(
            "Successfully initialized libhydrogen."
        )
    else
        netinst._utils.error(
            "Failed to initialize libhydrogen. Error: %s",
            libhydrogen
        )
    end

    -- Save the library in the global namespace and the package.loaded table
    package.loaded["libhydrogen"] = libhydrogen
    _G.libhydrogen = require("libhydrogen")
end
