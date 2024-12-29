local Utils = require("avante.utils")
local Path = require("plenary.path")
local scan = require("plenary.scandir")
local Config = require("avante.config")

local PROMPT_TITLE = "(Avante) Add a file"

--- @class FileSelector
local FileSelector = {}

--- @class FileSelector
--- @field id integer
--- @field selected_filepaths string[]
--- @field selected_file_ranges table<string, string[]>  -- map filepath to it ranges
--- @field file_cache string[]
--- @field event_handlers table<string, function[]>

---@alias FileSelectorHandler fun(self: FileSelector, on_select: fun(on_select: fun(filepath: string)|nil)): nil

---@param id integer
---@return FileSelector
function FileSelector:new(id)
  return setmetatable({
    id = id,
    selected_files = {},
    selected_filepaths = {},
    selected_file_ranges = {},
    file_cache = {},
    event_handlers = {},
  }, { __index = self })
end

function FileSelector:reset()
  self.selected_filepaths = {}
  self.selected_file_ranges = {}
  self.event_handlers = {}
end

function FileSelector:add_selected_file(filepath)
  if not filepath or filepath == "" then return end

  local uniform_path = Utils.uniform_path(filepath)
  -- Avoid duplicates
  if not vim.tbl_contains(self.selected_filepaths, uniform_path) then
    table.insert(self.selected_filepaths, uniform_path)
    self:emit("update")
  end
end

--- Add a file with specific line ranges
--- @param filepath string The file path
--- @param file_range string The line range in format "start_line-end_line" or empty string
function FileSelector:add_selected_file_ranges(filepath, file_range)
  if not filepath or filepath == "" then return end

  local uniform_path = Utils.uniform_path(filepath)

  -- Initialize ranges table if not exists
  if not self.selected_file_ranges[uniform_path] then self.selected_file_ranges[uniform_path] = {} end

  -- Add range if it's not empty and not already exists
  if file_range ~= "" then
    -- Check if range already exists
    local exists = false
    for _, existing_range in ipairs(self.selected_file_ranges[uniform_path]) do
      if existing_range == file_range then
        exists = true
        break
      end
    end

    if not exists then
      table.insert(self.selected_file_ranges[uniform_path], file_range)
      self:emit("update")
    end
  else
    -- add range "" to indicate all file is selected
    table.insert(self.selected_file_ranges[uniform_path], file_range)
    self:emit("update")
  end

  -- Although it is assumed filepath is added to selected_filepaths,
  -- add filepath if not already in selected_filepaths
  if not vim.tbl_contains(self.selected_filepaths, uniform_path) then
    table.insert(self.selected_filepaths, uniform_path)
    self:emit("update")
  end
end

function FileSelector:add_current_buffer()
  local current_buf = vim.api.nvim_get_current_buf()
  local filepath = vim.api.nvim_buf_get_name(current_buf)

  -- Only process if it's a real file buffer
  if filepath and filepath ~= "" and not vim.startswith(filepath, "avante://") then
    local relative_path = require("avante.utils").relative_path(filepath)

    -- Check if file is already in list
    for i, path in ipairs(self.selected_filepaths) do
      if path == relative_path then
        -- Remove if found
        table.remove(self.selected_filepaths, i)
        self:emit("update")
        return true
      end
    end

    -- Add if not found
    self:add_selected_file(relative_path)
    return true
  end
  return false
end

function FileSelector:on(event, callback)
  local handlers = self.event_handlers[event]
  if not handlers then
    handlers = {}
    self.event_handlers[event] = handlers
  end

  table.insert(handlers, callback)
end

function FileSelector:emit(event, ...)
  local handlers = self.event_handlers[event]
  if not handlers then return end

  for _, handler in ipairs(handlers) do
    handler(...)
  end
end

function FileSelector:off(event, callback)
  if not callback then
    self.event_handlers[event] = {}
    return
  end
  local handlers = self.event_handlers[event]
  if not handlers then return end

  for i, handler in ipairs(handlers) do
    if handler == callback then
      table.remove(handlers, i)
      break
    end
  end
end

---@return nil
function FileSelector:open()
  if Config.file_selector.provider == "native" then self:update_file_cache() end
  self:show_select_ui()
end

---@return nil
function FileSelector:update_file_cache()
  local project_root = Path:new(Utils.get_project_root()):absolute()

  local filepaths = scan.scan_dir(project_root, {
    respect_gitignore = true,
  })

  -- Sort buffer names alphabetically
  table.sort(filepaths, function(a, b) return a < b end)

  self.file_cache = vim
    .iter(filepaths)
    :map(function(filepath) return Path:new(filepath):make_relative(project_root) end)
    :totable()
end

---@type FileSelectorHandler
function FileSelector:fzf_ui(handler)
  local success, fzf_lua = pcall(require, "fzf-lua")
  if not success then
    Utils.error("fzf-lua is not installed. Please install fzf-lua to use it as a file selector.")
    return
  end

  local close_action = function() handler(nil) end
  fzf_lua.files(vim.tbl_deep_extend("force", Config.file_selector.provider_opts, {
    file_ignore_patterns = self.selected_filepaths,
    prompt = string.format("%s> ", PROMPT_TITLE),
    fzf_opts = {},
    git_icons = false,
    actions = {
      ["default"] = function(selected)
        local file = fzf_lua.path.entry_to_file(selected[1])
        handler(file.path)
      end,
      ["esc"] = close_action,
      ["ctrl-c"] = close_action,
    },
  }))
end

function FileSelector:telescope_ui(handler)
  local success, _ = pcall(require, "telescope")
  if not success then
    Utils.error("telescope is not installed. Please install telescope to use it as a file selector.")
    return
  end

  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")

  pickers
    .new(
      {},
      vim.tbl_extend("force", Config.file_selector.provider_opts, {
        file_ignore_patterns = self.selected_filepaths,
        prompt_title = string.format("%s> ", PROMPT_TITLE),
        finder = finders.new_oneshot_job({ "git", "ls-files" }, { cwd = Utils.get_project_root() }),
        sorter = conf.file_sorter(),
        attach_mappings = function(prompt_bufnr, map)
          map("i", "<esc>", require("telescope.actions").close)

          actions.select_default:replace(function()
            actions.close(prompt_bufnr)
            local selection = action_state.get_selected_entry()
            handler(selection[1])
          end)
          return true
        end,
      })
    )
    :find()
end

---@type FileSelectorHandler
function FileSelector:native_ui(handler)
  local filepaths = vim
    .iter(self.file_cache)
    :filter(function(filepath) return not vim.tbl_contains(self.selected_filepaths, filepath) end)
    :totable()

  vim.ui.select(filepaths, {
    prompt = string.format("%s:", PROMPT_TITLE),
    format_item = function(item) return item end,
  }, handler)
end

---@return nil
function FileSelector:show_select_ui()
  local handler = function(filepath)
    if not filepath then return end
    local uniform_path = Utils.uniform_path(filepath)
    if Config.file_selector.provider == "native" then
      -- Native handler filters out already selected files
      table.insert(self.selected_filepaths, uniform_path)
      self:emit("update")
    else
      if not vim.tbl_contains(self.selected_filepaths, uniform_path) then
        table.insert(self.selected_filepaths, uniform_path)
        self:emit("update")
      end
    end
  end

  vim.schedule(function()
    if Config.file_selector.provider == "native" then
      self:native_ui(handler)
    elseif Config.file_selector.provider == "fzf" then
      self:fzf_ui(handler)
    elseif Config.file_selector.provider == "telescope" then
      self:telescope_ui(handler)
    else
      Utils.error("Unknown file selector provider: " .. Config.file_selector.provider)
    end
  end)

  -- unlist the current buffer as vim.ui.select will be listed
  local winid = vim.api.nvim_get_current_win()
  local bufnr = vim.api.nvim_win_get_buf(winid)
  vim.api.nvim_set_option_value("buflisted", false, { buf = bufnr })
  vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = bufnr })
end

---@param idx integer
---@return boolean
function FileSelector:remove_selected_filepaths(idx)
  if idx > 0 and idx <= #self.selected_filepaths then
    table.remove(self.selected_filepaths, idx)
    self:emit("update")
    return true
  end
  return false
end

---@return { path: string, content: string, file_type: string }[]
function FileSelector:get_selected_files_contents()
  local contents = {}
  for _, file_path in ipairs(self.selected_filepaths) do
    local file = io.open(file_path, "r")
    if file then
      local all_lines = {}
      for line in file:lines() do
        table.insert(all_lines, line)
      end
      file:close()

      -- Detect the file type
      local filetype = vim.filetype.match({ filename = file_path }) or "unknown"

      -- Get the ranges for this file
      local ranges = self.selected_file_ranges[file_path] or {""}

      -- If ranges contains "", include the entire file
      if vim.tbl_contains(ranges, "") then
        table.insert(contents, {
          path = file_path,
          content = table.concat(all_lines, "\n"),
          file_type = filetype,
        })
      else
        -- Extract the lines for each range
        local selected_lines = {}
        for _, range in ipairs(ranges) do
          local start_line, end_line = range:match("^(%d+)%-(%d+)$")
          if start_line and end_line then
            start_line = tonumber(start_line)
            end_line = tonumber(end_line)
            for i = start_line, end_line do
              if all_lines[i] then
                table.insert(selected_lines, all_lines[i])
              end
            end
          end
        end
        table.insert(contents, {
          path = file_path,
          content = table.concat(selected_lines, "\n"),
          file_type = filetype,
        })
      end
    end
  end
  return contents
end

function FileSelector:get_selected_filepaths() return vim.deepcopy(self.selected_filepaths) end

---@return nil
function FileSelector:add_quickfix_files()
  local quickfix_files = vim
    .iter(vim.fn.getqflist({ items = 0 }).items)
    :filter(function(item) return item.bufnr ~= 0 end)
    :map(function(item) return Utils.relative_path(vim.api.nvim_buf_get_name(item.bufnr)) end)
    :totable()
  for _, filepath in ipairs(quickfix_files) do
    self:add_selected_file(filepath)
  end
end

-- local function test_add_get()
--   local filepath_test = "lua/avante/range.lua"
--   local filepath_test2 = "lua/avante/health.lua"
--   local file_range1 = "1-2"
--   local file_range2 = "4-4"
--   local file_selector = FileSelector:new(1)
--   file_selector:reset()
--   file_selector:add_selected_file(filepath_test)
--   file_selector:add_selected_file_ranges(filepath_test, file_range1)
--   file_selector:add_selected_file_ranges(filepath_test, file_range2)
--   file_selector:add_selected_file(filepath_test2)
--   file_selector:add_selected_file_ranges(filepath_test2, "")
--   vim.print(file_selector:get_selected_files_contents())
-- end

-- test_add_get()

return FileSelector
