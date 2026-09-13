local toml = require("crates.toml")
local DepKind = toml.DepKind
local state = require("crates.state")

local M = {}

---@param path string
---@return string
local function normalize_path(path)
    return vim.fs.normalize(path)
end

---@param buf integer
---@return string?
local function buf_path(buf)
    local name = vim.api.nvim_buf_get_name(buf)
    if name == "" then
        return nil
    end
    return normalize_path(name)
end

---@param path string
---@return integer?
local function loaded_buf_for_path(path)
    path = normalize_path(path)
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(buf) and buf_path(buf) == path then
            return buf
        end
    end
    return nil
end

---@param path string
---@return string[]?
local function read_file_lines(path)
    local f = io.open(path, "r")
    if not f then
        return nil
    end
    ---@type string[]
    local lines = {}
    for line in f:lines() do
        table.insert(lines, line)
    end
    f:close()
    return lines
end

---Lines of a Cargo.toml, preferring an unsaved loaded buffer.
---@param path string
---@return string[]?
---@return integer?
function M.lines_of(path)
    path = normalize_path(path)
    local buf = loaded_buf_for_path(path)
    if buf then
        return vim.api.nvim_buf_get_lines(buf, 0, -1, false), buf
    end
    return read_file_lines(path), nil
end

---Load (without showing) the buffer for `path`.
---@param path string
---@return integer
function M.ensure_buf(path)
    path = normalize_path(path)
    local buf = loaded_buf_for_path(path)
    if buf then
        return buf
    end
    buf = vim.fn.bufadd(path)
    vim.fn.bufload(buf)
    return buf
end

---@param line string
---@return boolean
local function is_workspace_header(line)
    line = toml.trim_comments(line)
    return line:match("^%s*%[%s*workspace%s*[%].]") ~= nil
end

---@param lines string[]
---@return boolean
function M.has_workspace_table(lines)
    for _, line in ipairs(lines) do
        if is_workspace_header(line) then
            return true
        end
    end
    return false
end

---`package.workspace = "relative/path"` if present.
---@param lines string[]
---@return string?
function M.package_workspace_path(lines)
    local in_package = false
    for _, line in ipairs(lines) do
        line = toml.trim_comments(line)
        local header = line:match("^%s*%[(.-)%]%s*$")
        if header then
            in_package = vim.trim(header) == "package"
        elseif in_package then
            local path = line:match([[^%s*workspace%s*=%s*["']([^"']+)["']%s*$]])
            if path then
                return path
            end
        end
    end
    return nil
end

---@param path string
---@return boolean
local function file_exists(path)
    local stat
    if vim.uv then
        stat = vim.uv.fs_stat(path)
    else
        stat = vim.loop.fs_stat(path)
    end
    return stat ~= nil and stat.type == "file"
end

---@param ... string
---@return string
local function join_path(...)
    if vim.fs.joinpath then
        return vim.fs.joinpath(...)
    end
    return table.concat({ ... }, "/")
end

---@param dir string
---@param rel string
---@return string
local function resolve_workspace_manifest(dir, rel)
    if rel:match("Cargo%.toml$") then
        return normalize_path(join_path(dir, rel))
    end
    return normalize_path(join_path(dir, rel, "Cargo.toml"))
end

---Find the workspace root Cargo.toml for a member (or root) manifest.
---@param manifest_path string
---@return string?
function M.find_root(manifest_path)
    manifest_path = normalize_path(manifest_path)
    local lines = M.lines_of(manifest_path)
    if lines then
        if M.has_workspace_table(lines) then
            return manifest_path
        end
        local rel = M.package_workspace_path(lines)
        if rel then
            local dir = vim.fs.dirname(manifest_path)
            local candidate = resolve_workspace_manifest(dir, rel)
            if file_exists(candidate) then
                return candidate
            end
        end
    end

    local dir = vim.fs.dirname(manifest_path)
    while dir and dir ~= "" do
        local candidate = normalize_path(join_path(dir, "Cargo.toml"))
        if candidate ~= manifest_path and file_exists(candidate) then
            local parent_lines = M.lines_of(candidate)
            if parent_lines and M.has_workspace_table(parent_lines) then
                return candidate
            end
        end
        local parent = vim.fs.dirname(dir)
        if not parent or parent == dir then
            break
        end
        dir = parent
    end

    return nil
end

---@param crates TomlCrate[]
---@return table<string, TomlCrate>
local function workspace_dep_map(crates)
    ---@type table<string, TomlCrate>
    local map = {}
    for _, c in ipairs(crates) do
        if c.section.workspace then
            map[c.explicit_name] = c
        end
    end
    return map
end

---Apply `[workspace.dependencies]` inheritance to member crates.
---@param crates TomlCrate[]
---@param workspace_crates TomlCrate[]
---@param root_path string?
function M.apply(crates, workspace_crates, root_path)
    local by_name = workspace_dep_map(workspace_crates)
    for _, c in ipairs(crates) do
        if c.workspace and c.workspace.enabled then
            c.workspace_root = root_path
            local ws = by_name[c.explicit_name]
            if ws then
                c.inherited = ws
                if ws.path then
                    c.dep_kind = DepKind.PATH
                elseif ws.git then
                    c.dep_kind = DepKind.GIT
                else
                    c.dep_kind = DepKind.REGISTRY
                end
            end
        end
    end
end

---Parse workspace.dependencies from the root manifest.
---@param root_path string
---@return TomlCrate[]
function M.parse_workspace_crates(root_path)
    local lines = M.lines_of(root_path)
    if not lines then
        return {}
    end
    local _, crates = toml.parse_crates_from_lines(lines)
    return crates
end

---Resolve workspace inheritance for crates parsed from `buf`.
---@param buf integer
---@param crates TomlCrate[]
function M.resolve(buf, crates)
    local path = buf_path(buf)
    local root_path = path and M.find_root(path) or nil
    if root_path then
        state.buf_to_root[buf] = root_path
    else
        state.buf_to_root[buf] = nil
    end

    if not root_path then
        M.apply(crates, crates, nil)
        return
    end

    local workspace_crates
    if path and normalize_path(path) == normalize_path(root_path) then
        workspace_crates = crates
    else
        workspace_crates = M.parse_workspace_crates(root_path)
    end
    M.apply(crates, workspace_crates, root_path)
end

---@class WorkspaceLocation
---@field filename string
---@field lnum integer -- 0-based
---@field col integer -- 0-based
---@field end_col integer -- 0-based exclusive

---@param root_path string
---@param path_text string
---@return string?
local function resolve_path_manifest(root_path, path_text)
    local base = vim.fs.dirname(root_path)
    local p = normalize_path(join_path(base, path_text))
    if p:match("Cargo%.toml$") and file_exists(p) then
        return p
    end
    local cargo = normalize_path(join_path(p, "Cargo.toml"))
    if file_exists(cargo) then
        return cargo
    end
    return nil
end

---Location of the workspace crate this dependency refers to.
---Path deps jump to that package's Cargo.toml; others jump to the
---`[workspace.dependencies]` entry in the workspace root.
---@param crate TomlCrate
---@param buf integer?
---@return WorkspaceLocation?
function M.definition_location(crate, buf)
    local root = crate.workspace_root or (buf and state.buf_to_root[buf])
    local src = crate.inherited or crate
    local path_text = src.path and src.path.text

    if path_text and root then
        local manifest = resolve_path_manifest(root, path_text)
        if manifest then
            return {
                filename = manifest,
                lnum = 0,
                col = 0,
                end_col = 0,
            }
        end
    end

    if crate.inherited and root then
        local name_col = src.explicit_name_col or { s = 0, e = 0 }
        return {
            filename = root,
            lnum = src.lines.s,
            col = name_col.s,
            end_col = name_col.e,
        }
    end

    return nil
end

---@param loc WorkspaceLocation
---@return lsp.Location
function M.lsp_location(loc)
    return {
        uri = vim.uri_from_fname(loc.filename),
        range = {
            start = { line = loc.lnum, character = loc.col },
            ["end"] = { line = loc.lnum, character = loc.end_col },
        },
    }
end

---Jump to the workspace crate definition for the crate on the current line.
---@return boolean
function M.goto_definition()
    local util = require("crates.util")
    local buf = util.current_buf()
    local line = util.cursor_pos()
    local _, crate = util.get_crate_on_line(buf, line)
    if not crate then
        util.notify(vim.log.levels.WARN, "No crate on the current line")
        return false
    end

    local loc = M.definition_location(crate, buf)
    if not loc then
        util.notify(vim.log.levels.WARN, "No workspace definition for this crate")
        return false
    end

    vim.cmd("normal! m'")
    vim.cmd.edit(vim.fn.fnameescape(loc.filename))
    local last = vim.api.nvim_buf_line_count(0)
    local lnum = math.max(0, math.min(loc.lnum, last - 1))
    pcall(vim.api.nvim_win_set_cursor, 0, { lnum + 1, loc.col })
    return true
end

return M
