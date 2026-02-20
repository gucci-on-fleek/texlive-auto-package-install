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



