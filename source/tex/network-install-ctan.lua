-- texlive-auto-package-install
-- https://github.com/gucci-on-fleek/texlive-auto-package-install
-- SPDX-License-Identifier: MPL-2.0+
-- SPDX-FileCopyrightText: 2026 Max Chernoff

--- This subpackage handles connecting to CTAN, downloading packages, and saving
--- them to the local filesystem.

----------------------
--- Initialization ---
----------------------

-- Make sure that the main package file is loaded first
if not netinst then
    require("network-install")
end
netinst._utils.debug("ctan subpackage loaded")


-----------------
--- Constants ---
-----------------

local mirror_redirector = "https://mirrors.ctan.org/"


----------------------
--- CTAN Downloads ---
----------------------

--- The URL to the chosen CTAN mirror.
--- @type string
local mirror_url do
    -- Try reading the mirror URL from the cache first
    local mirror_file, mirror_file_exists = netinst._get_ctan_mirror_file_path()
    if mirror_file_exists then
        -- Get the file
        local data = io.loaddata(mirror_file)
        if not data then
            netinst._utils.error(
                "Failed to read CTAN mirror file: %s",
                mirror_file
            )
        end

        -- Parse the file
        mirror_url = data:match("%S+")
        if not mirror_url then
            netinst._utils.error(
                "Failed to parse CTAN mirror URL from file: %s",
                mirror_file
            )
        end

        if not mirror_url:match("^https://") then
            netinst._utils.error(
                "Invalid CTAN mirror URL in file: %s. URL must start with https://",
                mirror_file
            )
        end

        -- Make sure the URL ends with a slash
        if not mirror_url:match("/$") then
            mirror_url = mirror_url .. "/"
        end

    -- Otherwise, choose a mirror and save it for next time
    else
        -- Fetch the URL
        local header, body, status = netinst.get_url(mirror_redirector)
        if (status < 300) or (status >= 400) then
            netinst._utils.error(
                "Failed to get CTAN mirror URL from redirector: %s. HTTP status code: %d",
                mirror_redirector,
                status
            )
        end

        local location = header.location
        if not location then
            netinst._utils.error(
                "Failed to get CTAN mirror URL from redirector: %s. No Location header found.",
                mirror_redirector
            )
        end

        if not location:match("^https://") then
            netinst._utils.error(
                "Invalid CTAN mirror URL from redirector: %s. URL must start with https://",
                mirror_redirector
            )
        end

        -- Save the URL to the cache for next time
        if not location:match("/$") then
            location = location .. "/"
        end
        mirror_url = location

        local ok = io.savedata(mirror_file, mirror_url)
        if not ok then
            netinst._utils.error(
                "Failed to save CTAN mirror URL to file: %s",
                mirror_file
            )
        end
    end

    netinst._utils.debug("Using CTAN mirror: %s", mirror_url)
end
