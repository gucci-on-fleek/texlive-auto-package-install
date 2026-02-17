-- texlive-auto-package-install
-- https://github.com/gucci-on-fleek/texlive-auto-package-install
-- SPDX-License-Identifier: MPL-2.0+
-- SPDX-FileCopyrightText: 2026 Max Chernoff

----------------------
--- Initialization ---
----------------------

-- Make sure that the main package file is loaded first
assert(
    netinst._currently_loading_subpackage,
    "This file cannot be loaded directly."
)
netinst._utils.debug("tex subpackage loaded")
