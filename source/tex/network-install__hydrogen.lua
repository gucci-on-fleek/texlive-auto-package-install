-- texlive-auto-package-install
-- https://github.com/gucci-on-fleek/texlive-auto-package-install
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


---------------
--- Loading ---
---------------

do
    -- Get the full path to the libhydrogen shared library
    local lib_name = ("libhydrogen-%s.%s"):format(
        os.platform, os.libsuffix
    )
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
