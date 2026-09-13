local config = require("crates.config")
local diagnostic = require("crates.diagnostic")
local edit = require("crates.edit")
local state = require("crates.state")
local toml = require("crates.toml")
local types = require("crates.types")
local workspace = require("crates.workspace")
local TomlCrateSyntax = toml.TomlCrateSyntax
local DepKind = toml.DepKind
local CratesDiagnosticKind = types.CratesDiagnosticKind

state.cfg = config.build({
    remove_empty_features = false,
})

---@param lines string[]
---@return TomlCrate[]
---@return integer
local function parse(lines)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    local _, crates = toml.parse_crates(buf)
    return crates, buf
end

---@param crates TomlCrate[]
---@param name string
---@return TomlCrate
local function crate_named(crates, name)
    for _, c in ipairs(crates) do
        if c.explicit_name == name then
            return c
        end
    end
    error("crate not found: " .. name)
end

---@param path string
---@param contents string
local function write_file(path, contents)
    vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
    local f = assert(io.open(path, "w"))
    f:write(contents)
    f:close()
end

---@param path string
---@return TomlCrate[]
---@return integer
---@return TomlSection[]
local function load_and_resolve(path)
    local buf = vim.fn.bufadd(path)
    vim.fn.bufload(buf)
    local sections, crates = toml.parse_crates(buf)
    workspace.resolve(buf, crates)
    return crates, buf, sections
end

---A small cargo workspace on disk:
---  root/Cargo.toml              [workspace] + [workspace.dependencies]
---  root/lib/Cargo.toml          path crate
---  root/app/Cargo.toml          member that inherits
---@return string tmp
local function make_workspace()
    local tmp = vim.fn.tempname()
    write_file(tmp .. "/Cargo.toml", table.concat({
        "[workspace]",
        'members = ["app", "lib"]',
        'resolver = "2"',
        "",
        "[workspace.package]",
        'edition = "2021"',
        "",
        "[workspace.dependencies]",
        'serde = "1.0.200"',
        'tokio = { version = "1.40", features = ["rt"] }',
        'lib = { path = "lib" }',
        'regex = { git = "https://github.com/rust-lang/regex" }',
        'cc.version = "1.0"',
        "",
        "[package]",
        'name = "workspace-root"',
        'version = "0.1.0"',
        "",
        "[dependencies]",
        "serde.workspace = true",
    }, "\n") .. "\n")
    write_file(tmp .. "/lib/Cargo.toml", table.concat({
        "[package]",
        'name = "lib"',
        'version = "0.1.0"',
    }, "\n") .. "\n")
    write_file(tmp .. "/app/Cargo.toml", table.concat({
        "[package]",
        'name = "app"',
        'version = "0.1.0"',
        "",
        "[dependencies]",
        "serde.workspace = true",
        'tokio = { workspace = true, features = ["macros"] }',
        "lib.workspace = true",
        "",
        "[dependencies.cc]",
        "workspace = true",
        "",
        "[dev-dependencies]",
        "regex.workspace = true",
        "",
        "[build-dependencies]",
        "cc.workspace = true",
    }, "\n") .. "\n")
    return tmp
end

describe("parse dotted workspace keys", function()
    it("parses dep.workspace = true", function()
        local crates = parse({
            "[dependencies]",
            "dep.workspace = true",
        })
        assert.equals(1, #crates)
        local crate = crates[1]
        assert.equals("dep", crate.explicit_name)
        assert.equals(TomlCrateSyntax.DOTTED, crate.syntax)
        assert.equals("true", crate.workspace.text)
        assert.is_true(crate.workspace.enabled)
        assert.equals(DepKind.WORKSPACE, crate.dep_kind)
    end)

    it("parses foo.workspace = true", function()
        local crates = parse({
            "[dependencies]",
            "mydep.workspace = true",
        })
        assert.equals(1, #crates)
        local crate = crates[1]
        assert.equals("mydep", crate.explicit_name)
        assert.equals(TomlCrateSyntax.DOTTED, crate.syntax)
        assert.is_true(crate.workspace.enabled)
        assert.equals(DepKind.WORKSPACE, crate.dep_kind)
        assert.is_true(crate:owns_line(1))
        assert.is_false(crate:owns_line(0))
        assert.equals(crate.workspace.line, crate:virt_text_line())
    end)

    it("parses inline table workspace = true", function()
        local crates = parse({
            "[dependencies]",
            'foo = { workspace = true, features = ["a"] }',
        })
        assert.equals(1, #crates)
        assert.equals(TomlCrateSyntax.INLINE_TABLE, crates[1].syntax)
        assert.is_true(crates[1].workspace.enabled)
        assert.equals("a", crates[1].feat.items[1].name)
    end)

    it("parses table crate workspace = true", function()
        local crates = parse({
            "[dependencies.foo]",
            "workspace = true",
        })
        assert.equals(1, #crates)
        assert.equals(TomlCrateSyntax.TABLE, crates[1].syntax)
        assert.is_true(crates[1].workspace.enabled)
        -- Section header is line 0; spinner/version sit on `workspace = true`.
        assert.equals(1, crates[1]:virt_text_line())
        assert.equals(0, crates[1].lines.s)
    end)

    it("merges adjacent dotted keys", function()
        local crates = parse({
            "[dependencies]",
            "foo.workspace = true",
            'foo.features = ["a", "b"]',
        })
        assert.equals(1, #crates)
        local crate = crates[1]
        assert.is_true(crate.workspace.enabled)
        assert.equals(2, #crate.feat.items)
        assert.equals("a", crate.feat.items[1].name)
        assert.equals(DepKind.WORKSPACE, crate.dep_kind)
        assert.is_true(crate:owns_line(1))
        assert.is_true(crate:owns_line(2))
    end)

    it("merges dotted keys split by another crate", function()
        local crates = parse({
            "[dependencies]",
            "foo.workspace = true",
            'bar = "1.0"',
            'foo.features = ["x"]',
        })
        assert.equals(2, #crates)
        local foo = crate_named(crates, "foo")
        local bar = crate_named(crates, "bar")
        assert.is_true(foo.workspace.enabled)
        assert.equals("x", foo.feat.items[1].name)
        assert.equals("1.0", bar.vers.text)
        assert.is_true(foo:owns_line(1))
        assert.is_false(foo:owns_line(2))
        assert.is_true(bar:owns_line(2))
        assert.is_true(foo:owns_line(3))
    end)

    it("parses multiline dotted features", function()
        local crates = parse({
            "[dependencies]",
            "foo.workspace = true",
            "foo.features = [",
            '    "net",',
            '    "rt",',
            "]",
        })
        local foo = crate_named(crates, "foo")
        assert.equals(2, #foo.feat.items)
        assert.equals("net", foo.feat.items[1].name)
        assert.equals("rt", foo.feat.items[2].name)
        assert.is_true(foo:owns_line(3))
        assert.is_true(foo:owns_line(4))
    end)

    it("treats foo.default-features as a dotted key", function()
        local crates = parse({
            "[dependencies]",
            "foo.default-features = false",
            'foo.version = "1.0"',
        })
        local foo = crate_named(crates, "foo")
        assert.is_false(foo.def.enabled)
        assert.equals("1.0", foo.vers.text)
        assert.is_nil(foo.workspace)
        assert.equals(DepKind.REGISTRY, foo.dep_kind)
    end)

    it("parses quoted names and spaces around the dot", function()
        local crates = parse({
            "[dependencies]",
            '"async-trait".workspace = true',
            "serde . workspace = true",
            "tokio.workspace          = true",
        })
        assert.equals("async-trait", crate_named(crates, "async-trait").explicit_name)
        assert.is_true(crate_named(crates, "async-trait").workspace.enabled)
        assert.is_true(crate_named(crates, "serde").workspace.enabled)
        assert.is_true(crate_named(crates, "tokio").workspace.enabled)
    end)

    it("parses CRLF dotted workspace keys", function()
        local crates = parse({
            "[dependencies]\r",
            "dep.workspace = true\r",
        })
        assert.equals(1, #crates)
        assert.equals("dep", crates[1].explicit_name)
        assert.is_true(crates[1].workspace.enabled)
    end)

    it("ignores unknown dotted suffixes", function()
        local crates = parse({
            "[dependencies]",
            "foo.not-a-key = true",
            "foo.workspace = true",
        })
        local foo = crate_named(crates, "foo")
        assert.is_true(foo.workspace.enabled)
        assert.equals(1, #crates)
    end)
end)

describe("workspace inherit", function()
    it("inherits version from workspace.dependencies", function()
        local ws = parse({
            "[workspace.dependencies]",
            'serde = "1.0.200"',
        })
        local members = parse({
            "[dependencies]",
            "serde.workspace = true",
        })
        workspace.apply(members, ws, "/tmp/Cargo.toml")
        local serde = members[1]
        assert.equals(DepKind.REGISTRY, serde.dep_kind)
        assert.equals("1.0.200", serde.inherited.vers.text)
        assert.equals("1.0.200", serde:vers_reqs()[1] and serde.inherited.vers.text)
        assert.equals("/tmp/Cargo.toml", serde.workspace_root)
        assert.equals(1, #serde:vers_reqs())
    end)

    it("inherits path as PATH kind", function()
        local ws = parse({
            "[workspace.dependencies]",
            'local-crate = { path = "../local-crate" }',
        })
        local members = parse({
            "[dependencies]",
            "local-crate = { workspace = true }",
        })
        workspace.apply(members, ws, "/tmp/Cargo.toml")
        assert.equals(DepKind.PATH, members[1].dep_kind)
    end)

    it("inherits git as GIT kind", function()
        local ws = parse({
            "[workspace.dependencies]",
            'regex = { git = "https://github.com/rust-lang/regex" }',
        })
        local members = parse({
            "[dependencies]",
            "regex.workspace = true",
        })
        workspace.apply(members, ws, "/tmp/Cargo.toml")
        assert.equals(DepKind.GIT, members[1].dep_kind)
    end)

    it("inherits package rename", function()
        local ws = parse({
            "[workspace.dependencies]",
            'foo = { version = "1.0", package = "bar" }',
        })
        local members = parse({
            "[dependencies]",
            "foo.workspace = true",
        })
        workspace.apply(members, ws, "/tmp/Cargo.toml")
        assert.equals("bar", members[1]:package())
    end)

    it("leaves missing keys as WORKSPACE", function()
        local ws = parse({
            "[workspace.dependencies]",
            'other = "1.0"',
        })
        local members = parse({
            "[dependencies]",
            "missing.workspace = true",
        })
        workspace.apply(members, ws, "/tmp/Cargo.toml")
        assert.equals(DepKind.WORKSPACE, members[1].dep_kind)
        assert.is_nil(members[1].inherited)
        assert.equals("/tmp/Cargo.toml", members[1].workspace_root)
    end)

    it("same-file inherit from workspace.dependencies", function()
        local crates = parse({
            "[workspace.dependencies]",
            'serde = "1"',
            "[dependencies]",
            "serde.workspace = true",
        })
        workspace.apply(crates, crates, "/tmp/Cargo.toml")
        local member = crate_named(crates, "serde")
        -- two serde crates: workspace section + member
        local member_only
        for _, c in ipairs(crates) do
            if c.explicit_name == "serde" and c.workspace then
                member_only = c
            end
        end
        assert.is_not_nil(member_only)
        assert.equals(DepKind.REGISTRY, member_only.dep_kind)
        assert.equals("1", member_only.inherited.vers.text)
        assert.equals(member.explicit_name, "serde")
    end)
end)

describe("workspace root discovery", function()
    local tmp

    before_each(function()
        tmp = vim.fn.tempname()
        vim.fn.mkdir(tmp, "p")
    end)

    after_each(function()
        vim.fn.delete(tmp, "rf")
    end)

    it("finds the nearest workspace root", function()
        write_file(tmp .. "/Cargo.toml", "[workspace]\nmembers = [\"crate\"]\n\n[workspace.dependencies]\nserde = \"1\"\n")
        write_file(tmp .. "/crate/Cargo.toml", "[package]\nname = \"crate\"\nversion = \"0.1.0\"\n")
        local root = workspace.find_root(tmp .. "/crate/Cargo.toml")
        assert.equals(vim.fs.normalize(tmp .. "/Cargo.toml"), root)
    end)

    it("treats a file with [workspace] as its own root", function()
        write_file(tmp .. "/Cargo.toml", "[workspace]\nmembers = []\n")
        local root = workspace.find_root(tmp .. "/Cargo.toml")
        assert.equals(vim.fs.normalize(tmp .. "/Cargo.toml"), root)
    end)

    it("follows package.workspace", function()
        write_file(tmp .. "/root/Cargo.toml", "[workspace]\nmembers = [\"nested/crate\"]\n")
        write_file(
            tmp .. "/root/nested/crate/Cargo.toml",
            "[package]\nname = \"crate\"\nversion = \"0.1.0\"\nworkspace = \"../..\"\n"
        )
        local root = workspace.find_root(tmp .. "/root/nested/crate/Cargo.toml")
        assert.equals(vim.fs.normalize(tmp .. "/root/Cargo.toml"), root)
    end)
end)

describe("workspace go-to-definition", function()
    local tmp

    before_each(function()
        tmp = vim.fn.tempname()
        vim.fn.mkdir(tmp, "p")
    end)

    after_each(function()
        vim.fn.delete(tmp, "rf")
    end)

    it("jumps to workspace.dependencies for a registry inherit", function()
        write_file(tmp .. "/Cargo.toml", "[workspace]\nmembers = [\"crate\"]\n\n[workspace.dependencies]\nserde = \"1.0.200\"\n")
        write_file(tmp .. "/crate/Cargo.toml", "[package]\nname = \"crate\"\nversion = \"0.1.0\"\n\n[dependencies]\nserde.workspace = true\n")

        local member_buf = vim.fn.bufadd(tmp .. "/crate/Cargo.toml")
        vim.fn.bufload(member_buf)
        local _, crates = toml.parse_crates(member_buf)
        workspace.resolve(member_buf, crates)
        local serde = crate_named(crates, "serde")
        local loc = workspace.definition_location(serde, member_buf)
        assert.is_not_nil(loc)
        assert.equals(vim.fs.normalize(tmp .. "/Cargo.toml"), loc.filename)
        assert.equals(4, loc.lnum)
    end)

    it("jumps to the path crate Cargo.toml for a path inherit", function()
        write_file(tmp .. "/Cargo.toml", "[workspace]\nmembers = [\"app\", \"lib\"]\n\n[workspace.dependencies]\nlib = { path = \"lib\" }\n")
        write_file(tmp .. "/lib/Cargo.toml", "[package]\nname = \"lib\"\nversion = \"0.1.0\"\n")
        write_file(tmp .. "/app/Cargo.toml", "[package]\nname = \"app\"\nversion = \"0.1.0\"\n\n[dependencies]\nlib.workspace = true\n")

        local member_buf = vim.fn.bufadd(tmp .. "/app/Cargo.toml")
        vim.fn.bufload(member_buf)
        local _, crates = toml.parse_crates(member_buf)
        workspace.resolve(member_buf, crates)
        local lib = crate_named(crates, "lib")
        local loc = workspace.definition_location(lib, member_buf)
        assert.is_not_nil(loc)
        assert.equals(vim.fs.normalize(tmp .. "/lib/Cargo.toml"), loc.filename)
    end)
end)

describe("emulated workspace", function()
    local tmp

    before_each(function()
        tmp = make_workspace()
    end)

    after_each(function()
        vim.fn.delete(tmp, "rf")
    end)

    it("resolves dotted, inline, and table inherits from a member Cargo.toml", function()
        local crates = load_and_resolve(tmp .. "/app/Cargo.toml")

        local serde = crate_named(crates, "serde")
        assert.equals(TomlCrateSyntax.DOTTED, serde.syntax)
        assert.equals(DepKind.REGISTRY, serde.dep_kind)
        assert.equals("1.0.200", serde.inherited.vers.text)
        assert.equals(1, #serde:vers_reqs())
        assert.equals(serde.workspace.line, serde:virt_text_line())

        local tokio = crate_named(crates, "tokio")
        assert.equals(TomlCrateSyntax.INLINE_TABLE, tokio.syntax)
        assert.equals(DepKind.REGISTRY, tokio.dep_kind)
        assert.equals("1.40", tokio.inherited.vers.text)
        assert.equals("macros", tokio.feat.items[1].name)
        assert.equals("rt", tokio.inherited.feat.items[1].name)

        local lib = crate_named(crates, "lib")
        assert.equals(DepKind.PATH, lib.dep_kind)
        assert.equals("lib", lib.inherited.path.text)

        local regex
        for _, c in ipairs(crates) do
            if c.explicit_name == "regex" then
                regex = c
            end
        end
        assert.is_not_nil(regex)
        assert.equals(DepKind.GIT, regex.dep_kind)

        local cc_table
        for _, c in ipairs(crates) do
            if c.explicit_name == "cc" and c.syntax == TomlCrateSyntax.TABLE then
                cc_table = c
            end
        end
        assert.is_not_nil(cc_table)
        assert.equals(DepKind.REGISTRY, cc_table.dep_kind)
        assert.equals("1.0", cc_table.inherited.vers.text)
    end)

    it("inherits in the root package from the same Cargo.toml", function()
        local crates = load_and_resolve(tmp .. "/Cargo.toml")
        local serde
        for _, c in ipairs(crates) do
            if c.explicit_name == "serde" and c.workspace then
                serde = c
            end
        end
        assert.is_not_nil(serde)
        assert.equals(DepKind.REGISTRY, serde.dep_kind)
        assert.equals("1.0.200", serde.inherited.vers.text)
    end)

    it("reads workspace.dependencies from disk when the root is not loaded", function()
        local crates = load_and_resolve(tmp .. "/app/Cargo.toml")
        assert.equals("1.0.200", crate_named(crates, "serde").inherited.vers.text)
    end)

    it("prefers unsaved root buffer contents over disk", function()
        local root_buf = vim.fn.bufadd(tmp .. "/Cargo.toml")
        vim.fn.bufload(root_buf)
        vim.api.nvim_buf_set_lines(root_buf, 0, -1, false, {
            "[workspace]",
            'members = ["app"]',
            "",
            "[workspace.dependencies]",
            'serde = "9.9.9"',
        })

        local crates = load_and_resolve(tmp .. "/app/Cargo.toml")
        assert.equals("9.9.9", crate_named(crates, "serde").inherited.vers.text)
    end)

    it("diagnoses a missing workspace.dependencies key", function()
        write_file(tmp .. "/app/Cargo.toml", table.concat({
            "[package]",
            'name = "app"',
            'version = "0.1.0"',
            "",
            "[dependencies]",
            "not-in-workspace.workspace = true",
        }, "\n") .. "\n")

        local crates, _, sections = load_and_resolve(tmp .. "/app/Cargo.toml")
        local _, diags = diagnostic.process_crates(sections, crates)
        local found
        for _, d in ipairs(diags) do
            if d.kind == CratesDiagnosticKind.WORKSPACE_DEP_MISSING then
                found = d
            end
        end
        assert.is_not_nil(found)
    end)

    it("diagnoses a missing workspace root", function()
        -- Must sit outside the emulated workspace so walk-up does not find it.
        local lone_dir = vim.fn.tempname()
        local lone = lone_dir .. "/Cargo.toml"
        write_file(lone, table.concat({
            "[package]",
            'name = "orphan"',
            'version = "0.1.0"',
            "",
            "[dependencies]",
            "serde.workspace = true",
        }, "\n") .. "\n")

        local crates, _, sections = load_and_resolve(lone)
        local serde = crate_named(crates, "serde")
        assert.equals(DepKind.WORKSPACE, serde.dep_kind)
        assert.is_nil(serde.inherited)

        local _, diags = diagnostic.process_crates(sections, crates)
        local found
        for _, d in ipairs(diags) do
            if d.kind == CratesDiagnosticKind.WORKSPACE_NO_ROOT then
                found = d
            end
        end
        assert.is_not_nil(found)
        vim.fn.delete(lone_dir, "rf")
    end)

    it("diagnoses an invalid workspace boolean", function()
        local buf = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
            "[dependencies]",
            "serde.workspace = maybe",
        })
        local sections, crates = toml.parse_crates(buf)
        local _, diags = diagnostic.process_crates(sections, crates)
        local found
        for _, d in ipairs(diags) do
            if d.kind == CratesDiagnosticKind.WORKSPACE_INVALID then
                found = d
            end
        end
        assert.is_not_nil(found)
    end)

    it("inherits target-specific dotted workspace deps", function()
        write_file(tmp .. "/app/Cargo.toml", table.concat({
            "[package]",
            'name = "app"',
            'version = "0.1.0"',
            "",
            "[target.'cfg(unix)'.dependencies]",
            "serde.workspace = true",
        }, "\n") .. "\n")

        local crates = load_and_resolve(tmp .. "/app/Cargo.toml")
        local serde = crate_named(crates, "serde")
        assert.equals(DepKind.REGISTRY, serde.dep_kind)
        assert.equals("1.0.200", serde.inherited.vers.text)
        assert.is_not_nil(serde.section.target)
    end)

    it("jumps from the member to the path crate Cargo.toml", function()
        local crates, buf = load_and_resolve(tmp .. "/app/Cargo.toml")
        local loc = workspace.definition_location(crate_named(crates, "lib"), buf)
        assert.is_not_nil(loc)
        assert.equals(vim.fs.normalize(tmp .. "/lib/Cargo.toml"), loc.filename)
    end)

    it("jumps from the member to the workspace.dependencies pin", function()
        local crates, buf = load_and_resolve(tmp .. "/app/Cargo.toml")
        local loc = workspace.definition_location(crate_named(crates, "serde"), buf)
        assert.is_not_nil(loc)
        assert.equals(vim.fs.normalize(tmp .. "/Cargo.toml"), loc.filename)
        local root_lines = vim.split(assert(io.open(tmp .. "/Cargo.toml"):read("*a")), "\n")
        assert.is_not_nil(root_lines[loc.lnum + 1]:find("serde", 1, true))
    end)

    it("edits the workspace pin without changing the member", function()
        local crates, member_buf = load_and_resolve(tmp .. "/app/Cargo.toml")
        local semver = require("crates.semver")
        edit.set_version(member_buf, crate_named(crates, "serde"), semver.parse_version("1.0.210"))

        local root_buf = workspace.ensure_buf(vim.fs.normalize(tmp .. "/Cargo.toml"))
        local root_text = table.concat(vim.api.nvim_buf_get_lines(root_buf, 0, -1, false), "\n")
        assert.is_not_nil(root_text:find('serde = "1.0.210"', 1, true))
        local member_text = table.concat(vim.api.nvim_buf_get_lines(member_buf, 0, -1, false), "\n")
        assert.is_not_nil(member_text:find("serde.workspace = true", 1, true))
        assert.is_nil(member_text:find("1.0.210", 1, true))
    end)
end)

describe("edit dotted workspace crates", function()
    it("enables a feature as a dotted key", function()
        local crates, buf = parse({
            "[dependencies]",
            "foo.workspace = true",
        })
        edit.enable_feature(buf, crates[1], "derive")
        local result = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
        assert.equals("foo.workspace = true", result[2])
        assert.equals('foo.features = ["derive"]', result[3])
    end)

    it("disables a dotted feature", function()
        local crates, buf = parse({
            "[dependencies]",
            "foo.workspace = true",
            'foo.features = ["a", "b"]',
        })
        local foo = crate_named(crates, "foo")
        edit.disable_feature(buf, foo, foo.feat.items[1])
        local result = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
        assert.is_nil(result[3]:find('"a"', 1, true))
        assert.is_not_nil(result[3]:find('"b"', 1, true))
    end)

    it("extracts a dotted crate into a table with unquoted workspace", function()
        local crates, buf = parse({
            "[dependencies]",
            "foo.workspace = true",
            'foo.features = ["a"]',
        })
        edit.extract_crate_into_table(buf, crates[1])
        local result = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
        local text = table.concat(result, "\n")
        assert.is_not_nil(text:find("%[dependencies%.foo%]", 1))
        assert.is_not_nil(text:find("workspace = true", 1, true))
        assert.is_nil(text:find('workspace = "true"', 1, true))
        assert.is_not_nil(text:find("features = ", 1, true))
    end)

    it("set_version of an inherited crate edits the workspace buffer", function()
        local ws_lines = {
            "[workspace.dependencies]",
            'serde = "1.0.0"',
        }
        local ws_buf = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_lines(ws_buf, 0, -1, false, ws_lines)
        -- Named path so ensure_buf / lines_of can find it.
        local ws_path = vim.fn.tempname() .. "/Cargo.toml"
        vim.fn.mkdir(vim.fn.fnamemodify(ws_path, ":h"), "p")
        vim.api.nvim_buf_set_name(ws_buf, ws_path)

        local ws_crates = select(2, toml.parse_crates(ws_buf))
        local members, member_buf = parse({
            "[dependencies]",
            "serde.workspace = true",
        })
        workspace.apply(members, ws_crates, ws_path)
        local semver = require("crates.semver")
        edit.set_version(member_buf, members[1], semver.parse_version("1.0.200"))

        local result = vim.api.nvim_buf_get_lines(ws_buf, 0, -1, false)
        assert.equals('serde = "1.0.200"', result[2])
        local member_result = vim.api.nvim_buf_get_lines(member_buf, 0, -1, false)
        assert.equals("serde.workspace = true", member_result[2])

        vim.fn.delete(vim.fn.fnamemodify(ws_path, ":h"), "rf")
    end)
end)
