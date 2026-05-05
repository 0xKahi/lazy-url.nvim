local M = {}

---Strip trailing punctuation from a URL.
---The double-parens discard gsub's second return value (match count).
---@param url string
---@return string
function M._strip_trailing(url)
  return (url:gsub('[%.%,%;%:%!%?%)]+$', ''))
end

---Find a URL from the current context.
---Detection chain (first non-nil wins):
---  1. Visual selection (if mode starts with 'v') — extracts first https?:// match
---  2. vim.ui._get_urls() — Neovim built-in (LSP documentLink, extmarks, treesitter)
---  3. Markdown link [label](url) — cursor column must fall within match span
---  4. Bare URL on cursor line — cursor column must fall within match span
---  5. <cfile> fallback
---  6. nil
---@return string | nil
function M.find()
  -- 1. Visual mode: extract URL from selection
  local mode = vim.fn.mode()
  if mode:sub(1, 1):lower() == 'v' then
    local lines = vim.fn.getregion(vim.fn.getpos('.'), vim.fn.getpos('v'), { type = mode })
    local text = vim.trim(table.concat(lines, ' '))
    local url = text:match('https?://[%w%-%._~%%/%?#&=@_%+%:!%$%,%;]+')
    if url then
      return M._strip_trailing(url)
    end
    if text:match('^https?://') then
      return M._strip_trailing(text)
    end
    -- Visual mode but no URL found — do NOT fall through to cursor detection
    return nil
  end

  -- 2. Try Neovim's built-in URL detector (LSP documentLink, extmarks, treesitter @url)
  -- Filter results to scheme-prefixed URLs so step 5 owns the cfile fallback exclusively.
  if vim.ui._get_urls then
    local ok, urls = pcall(vim.ui._get_urls)
    if ok and urls then
      for _, u in ipairs(urls) do
        if u and u ~= '' and u:match('^%a[%a%d%+%-%.]*://') then
          return M._strip_trailing(u)
        end
      end
    end
  end

  -- 3 & 4. Scan current line for markdown links and bare URLs
  local line = vim.api.nvim_get_current_line()
  local col = vim.api.nvim_win_get_cursor(0)[2] -- 0-based column

  -- 3. Markdown link: [label](url)
  local i = 1
  while i <= #line do
    local s, e, url = line:find('%[.-%]%((%a[%a%d%+%-%.]-%://[^%)%s]+)%)', i)
    if not s then
      break
    end
    if col >= s - 1 and col < e then
      return M._strip_trailing(url)
    end
    i = e + 1
  end

  -- 4. Bare URL on line
  i = 1
  while i <= #line do
    local s, e, url = line:find('(https?://[%w%-%._~%%/%?#&=@_%+%:!%$%,%;]+)', i)
    if not s then
      break
    end
    if col >= s - 1 and col < e then
      return M._strip_trailing(url)
    end
    i = e + 1
  end

  -- 5. <cfile> fallback
  local cf = vim.fn.expand('<cfile>')
  if cf and cf:match('^https?://') then
    return M._strip_trailing(cf)
  end

  return nil
end

return M
