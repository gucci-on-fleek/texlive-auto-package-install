-- texlive-auto-package-install
-- https://github.com/gucci-on-fleek/texlive-auto-package-install
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


-----------------
--- Constants ---
-----------------



