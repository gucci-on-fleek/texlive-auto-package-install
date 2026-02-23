-- texlive-auto-package-install
-- https://github.com/gucci-on-fleek/texlive-auto-package-install
-- SPDX-License-Identifier: MPL-2.0+
-- SPDX-FileCopyrightText: 2026 Max Chernoff


-- Initialization
module = "texlive-auto-package-install"
local version = "0.2.0" --%%version
local date = "2026-02-23" --%%dashdate

local orig_targets = target_list
target_list = {}

-- Tagging
target_list.tag = orig_targets.tag
tagfiles = { "source/*.*", "docs/**/*.*", "README.md", "build.lua" }

function update_tag(name, content, version, date)
    if not version then
        print("No version provided. Exiting")
        os.exit(1)
    end

    if name:match("%.pdf$") then
        return content
    end

    content = content:gsub(
        "(%d%.%d%.%d)([^\n]*)%%%%version",
        version .. "%2%%%%version"
    ):gsub(
        "(%d%d%d%d%-%d%d%-%d%d)([^\n]*)%%%%dashdate",
        date .. "%2%%%%dashdate"
    ):gsub(
        "(%d%d%d%d/%d%d/%d%d)([^\n]*)%%%%slashdate",
        date:gsub("-", "/") .. "%2%%%%slashdate"
    )

    return content
end

-- Bundle
target_list.bundle = {}
target_list.bundle.desc = "Creates the package zipfiles"

function target_list.bundle.func()
    local newzip = require "l3build-zip"
    local name = module .. "-" .. version
    local tdszipname = name .. ".tds.zip"
    local ctanzipname = name .. ".ctan.zip"

    local tdszip = newzip("./" .. tdszipname)
    local ctanzip = newzip("./" .. ctanzipname)

    for _, path in ipairs(tree("texmf", "**/*.*")) do
        tdszip:add(
            path.cwd, -- outer
            path.src:sub(3), -- inner
            path.src:match("pdf") -- binary
        )
        ctanzip:add(
            path.cwd, -- outer
            module .. "/" .. basename(path.src), -- inner
            path.src:match("pdf") -- binary
        )
    end

    tdszip:close()

    -- CTAN doesn't want this as per email from Petra and Karl
    -- ctanzip:add("./" .. tdszipname, tdszipname, true)
    ctanzip:close()

    local release_notes = io.open("release.title", "w")
    release_notes:write(version .. " " .. date .. "\n")
    release_notes:close()

    return 0
end

-- Documentation
target_list.doc = {}
target_list.doc.desc = "Builds the documentation"

local l3_run = run
local function run(cwd, cmd)
    local error = l3_run(cwd, cmd)
    if error ~= 0 then
        print(("\n"):rep(5))
        print("Error code " .. error .. " for command " .. cmd .. ".")
        print("\n")
        os.exit(1)
    end
end

function target_list.doc.func()
    run("./documentation", "context manual")
    return 0
end

-- Tests
target_list.check = orig_targets.check
target_list.save = orig_targets.save

os_diffexe = "git diff --no-index -w --word-diff --text"

testfiledir = "./tests/"
tdsdirs = { ["./texmf"] = "." }
maxprintline = 10000
checkengines = { "lualatex", "lualatex-dev" }
