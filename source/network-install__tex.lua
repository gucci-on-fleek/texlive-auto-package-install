-- texlive-auto-package-install
-- https://github.com/gucci-on-fleek/texlive-auto-package-install
-- SPDX-License-Identifier: MPL-2.0+
-- SPDX-FileCopyrightText: 2026 Max Chernoff

----------------------
--- Initialization ---
----------------------

assert(
    netinst._currently_loading_subpackage,
    "This file cannot be loaded directly."
)

netinst._utils.info("``tex'' subpackage loaded.")
