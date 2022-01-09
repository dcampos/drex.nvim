local M = {}

local api = vim.api
local luv = vim.loop
local utils = require('drex.utils')
local fs = require('drex.fs')

---Private table to store buffer specific autocommand functions
local buffer_autocmds = {}

---Call a buffer specific autocommand function (if there is one)
---This is only intended for the usage within autocommands
---@param buffer number Buffer handle
function M.call_buf_autocmd(buffer)
    local fn = buffer_autocmds[buffer]
    if fn then
        fn()
    end
end

M.clipboard = {}

-- ####################################
-- ### local utility functions
-- ####################################

---Return all elements currently contained in the DREX clipboard
---You can specify a sort order ('asc' or 'desc'), otherwise the elements might be returned in any order
---
---If you want to perform any actions on the contained elements you should set the `sort_order` to 'desc' so that more detailed paths occur first in the result list
---
---<pre>
---{
---  "/home/user/dir/file.txt",
---  "/home/user/dir",
---}
---</pre>
---
---This should be done so that all performed actions have a deterministic outcome
---In the above example `copy_and_paste` would first copy `file.txt` to the destination and then copy `dir` (including `file.txt` within it's content)
---
---<pre>
---destination/
---- file.txt
---- dir/
---  - file.txt
---  - ...
---</pre>
---
---Otherwise the `copy_and_paste` function would sometimes not be deterministic, depending on the order of the clipboard entries
---@param sort_order string (Optional) If provided sort the clipboard entries accordingly ('asc' or 'desc')
---@return table
local function get_clipboard_entries(sort_order)
    local clipboard_entries = vim.tbl_keys(M.clipboard)

    if sort_order == 'asc' then
        table.sort(clipboard_entries)
    elseif sort_order == 'desc' then
        table.sort(clipboard_entries, function(a, b) return a > b end)
    end

    return clipboard_entries
end

---Reload the syntax option in all currently visible DREX buffer
local function reload_drex_syntax()
    for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
        local buffer = api.nvim_win_get_buf(win)
        if api.nvim_buf_get_option(buffer, 'filetype') == 'drex' then
            api.nvim_buf_call(buffer, function() vim.cmd('doautocmd Syntax') end)
        end
    end
end

---Retrieve the start and end row of the current or last visual selection
---@return number
---@return number
local function visual_selected_rows()
    local startRow = vim.fn.getpos("'<")[2]
    local endRow   = vim.fn.getpos("'>")[2]
    if startRow < endRow then
        return startRow, endRow
    else
        return endRow, startRow
    end
end

---Reset the undo history for `buffer`
---@param buffer number Buffer handle, or 0 for current buffer
local function buf_clear_undo_history(buffer)
    -- local old_undolevels = vim.opt.undolevels:get()
    -- api.nvim_buf_set_option(buffer, 'undolevels', -1)
    -- api.nvim_buf_call(buffer, function()
    --     vim.cmd(api.nvim_replace_termcodes('normal a <BS><ESC>', true, true, true))
    -- end)
    -- api.nvim_buf_set_option(buffer, 'undolevels', old_undolevels)

    -- in current stable version there is a bug so we have to perform this in VIML till 0.7
    -- see: https://github.com/neovim/neovim/pull/15996
    api.nvim_buf_call(buffer, function()
        vim.cmd [[
            let old_undolevels = &undolevels
            set undolevels=-1
            exe "normal a \<BS>\<ESC>"
            let &undolevels = old_undolevels
            unlet old_undolevels
        ]]
    end)
end

---Return the path of the current line as destination path
---If the line represents a directory ask the user if the destination should be inside this directory or on the same level instead
---If the user does not choose any option but cancels instead return `nil`
---@return string
local function get_destination_path()
    local line = api.nvim_get_current_line()

    if utils.is_directory(line) then
        local same_level_path = utils.get_path(line)
        local inside_path     = utils.get_element(line) .. utils.path_separator

        local target = vim.fn.inputlist({
            'Please choose the specific destination:',
            '1. ' .. same_level_path,
            '2. ' .. inside_path,
        })
        vim.cmd('redraw') -- clear input area

        if target == 1 then
            return same_level_path
        elseif target == 2 then
            return inside_path
        else
            return
        end
    else
        return utils.get_path(line)
    end
end

---Copy an element from `source` to `destination`
---For files this simply uses `vim.loop.fs_copyfile`
---For directories this will loop through all contained files (using `vim.loop.fs_scandir`) and recursively call itself
---@param source string The source location of the element that should be copied
---@param destination string The destination location to which the element should be copied
local function copy(source, destination)
    local source_stats = luv.fs_stat(source)
    if source_stats and source_stats.type == 'file' then
        luv.fs_copyfile(source, destination, {})
        return
    end

    local data, error, _ = luv.fs_scandir(source)
    if error ~= nil then
        api.nvim_err_writeln(error)
        return
    end

    luv.fs_mkdir(destination, source_stats.mode)

    while true do
        local name, _ = luv.fs_scandir_next(data)

        if not name then
            break
        end

        local src_path  = source .. utils.path_separator .. name
        local dest_path = destination .. utils.path_separator .. name
        copy(src_path, dest_path)
    end
end

---Search for buffers named `old_name` and rename them to `new_name`
---@param old_name string
---@param new_name string
local function rename_loaded_buffers(old_name, new_name)
    for _, buf in ipairs(api.nvim_list_bufs()) do
        if api.nvim_buf_is_loaded(buf) then
            local buf_name = api.nvim_buf_get_name(buf)
            if utils.starts_with(buf_name, old_name) then
                local new_buf_name = buf_name:gsub(utils.escape(old_name), new_name)
                api.nvim_buf_set_name(buf, new_buf_name)
                -- avoid 'overwrite existing file' error
                api.nvim_buf_call(buf, function() vim.cmd('silent! w!') end)
            end
        end
    end
end

---Paste all DREX clipboard entries at the current location
---This will show a warning if there are no elements in the clipboard
---
---If you "copy" entries (`move` == false) the DREX clipboard entries will be untouched
---
---So you can continue copying the contained elements to other locations
---If you "move" entries (`move` == true) the DREX clipboard entries will be updated to match the new location
---
---@param move boolean Indicator if the entries should be moved (removed from their current location) or copied
local function paste(move)
    local elements = get_clipboard_entries('desc')

    -- check for an empty clipboard
    if vim.tbl_count(elements) == 0 then
        local action_string = move and 'move' or 'paste'
        vim.notify('The clipboard is empty! There is nothing to ' .. action_string .. '...', vim.log.levels.INFO, { title = 'DREX' })
        return
    end

    local dest_path = get_destination_path()
    if not dest_path then
        return
    end

    for _, element in ipairs(elements) do
        local name = element:match('.*'..utils.path_separator..'(.*)$')
        local new_element = dest_path .. name

        ::rename_check::
        -- check if the an element with the same name already exists
        local new_element_stats = luv.fs_stat(new_element)
        local action = 1
        if new_element_stats then
             action = vim.fn.confirm(new_element .. ' already exists. Overwrite?', '&Yes\n&No\n&Rename', 2)
        end

        if action ~= 2 then     -- user did NOT choose 'No'
            if action == 3 then -- user did choose 'Rename'
                new_element = vim.fn.input('New name: ', new_element)
                goto rename_check
            end

            if move then
                local success, error = luv.fs_rename(element, new_element)
                if success then
                    rename_loaded_buffers(element, new_element)
                    M.clipboard[element] = nil
                    M.clipboard[new_element] = true
                else
                    vim.notify("Could not move '" .. element .. "':\n" .. error, vim.log.levels.ERROR, { title = 'DREX' })
                end
            else
                copy(element, new_element)
            end
        end
    end

    if move then
        reload_drex_syntax()
    end
end

---Create all non-existent directories of `path`
---This will not create files but only directories!
---
---For example:
---'/home/user/dir/test.json' will create the directories 'home', 'user' and 'dir' (if they do not exists already) but NOT the file 'test.json'
---
---The return value is a table containing two entries:
---- The part of the path which did already exist
---- The part of the path which was created by this function (or `nil` if nothing was created)
---
---For example:
---<pre>
---{ '/home/user/', '/test' }
---</pre>
---
---@param path string The path to create directories for (absolute path)
---@return table
local function create_directories(path)
    local path_segments = vim.split(path, utils.path_separator)

    -- if path does not start with '/' or 'C:\' it is not absolute
    if not (path_segments[1] == "" or path_segments[1]:find('[a-zA-Z]:')) then
        -- todo? log into some debug file
        return
    end

    local tmp_path = path_segments[1]
    -- remove first "" or "C:" entry
    table.remove(path_segments, 1)
    -- remove "" or the file name from the end of the list
    table.remove(path_segments, #path_segments)

    local existing_path -- part of `path` which does already exist
    local created_path  -- part of `path` which was created

    for _, segment in ipairs(path_segments) do
        local parent_path = tmp_path .. utils.path_separator

        tmp_path = tmp_path .. utils.path_separator .. segment
        local success = luv.fs_mkdir(tmp_path, 493)

        -- the first nonexistent part of `path` was created
        if not existing_path and success then
            existing_path = parent_path
            created_path = path:gsub(utils.escape(parent_path), '', 1)
        end
    end

    -- no directory needed to be created
    if not existing_path then
        existing_path = tmp_path .. utils.path_separator
    end

    return { existing_path, created_path }
end

---Recursively delete a directory and all of its content
---If an error occurs during the process return its message, otherwise return `nil`
---@param path string The directory to delete
---@return string
local function delete_directory(path)
    local data, error = luv.fs_scandir(path)
    if error then
        return error
    end

    while true do
        local name, type = luv.fs_scandir_next(data)

        if not name then
            break
        end

        local new_path = path .. utils.path_separator .. name
        if type == 'directory' then
            error = delete_directory(new_path)
        else
            _, error = luv.fs_unlink(new_path)
        end

        if error then
            return error
        end
    end

    _, error = luv.fs_rmdir(path)
    return error
end

-- ####################################
-- ### clipboard related functions
-- ####################################

---Edit all DREX clipboard entries in a floating window
---Some important notes:
---- The clipboard is updated once you leave the buffer or close the window
---- Empty lines and comments (starting with '#') will be ignored
---- Invalid paths will also be ignored
function M.open_clipboard_window()
    local elements = get_clipboard_entries('asc')
    local buf_lines = {
        '# DREX CLIPBOARD',
        '',
        '# Confirm changes by leaving this buffer or closing the window and approve the',
        "# confirmation (only if changes exist). Empty lines, comments starting with '#'",
        '# and non-existing elements will be ignored and not added to the clipboard',
        '',
        unpack(elements)
    }

    local buffer = api.nvim_create_buf(false, true)
    api.nvim_buf_set_lines(buffer, 0, -1, false, buf_lines)
    api.nvim_buf_set_option(buffer, 'buftype', 'nofile')
    api.nvim_buf_set_option(buffer, 'bufhidden', 'wipe')
    api.nvim_buf_set_option(buffer, 'syntax', 'gitcommit')
    api.nvim_buf_set_name(buffer, 'DREX Clipboard')
    buf_clear_undo_history(buffer)

    local vim_width = vim.opt.columns:get()
    local vim_height = vim.opt.lines:get()

    -- calculate floating window dimensions
    -- - height: 80% of the Neovim window
    -- - width:
    --   - 60% of Neovim window (default)
    --   - or at least 80 columns
    --   - or as long as the longest element (if enough space)
    local win_height = math.floor(vim_height * 0.8)
    local win_width = math.floor(vim_width * 0.6)

    win_width = win_width < 80 and 80 or win_width
    local max_element_width = vim.fn.max(vim.tbl_map(function(element) return #element end, elements))
    if max_element_width > win_width then
        if max_element_width > vim_width - 10 then
            win_width = vim_width - 10
        else
            win_width = max_element_width
        end
    end

    local x = math.floor((vim_width - win_width) / 2)
    local y = math.floor((vim_height - win_height) / 2)

    local clipboard_win = api.nvim_open_win(buffer, true, {
        relative = 'editor',
        width = win_width,
        height = win_height,
        col = x,
        row = y,
        style = 'minimal',
        border = 'rounded',
        noautocmd = false,
    })
    api.nvim_win_set_option(clipboard_win, 'wrap', false)

    buffer_autocmds[buffer] = function()
        local buf_elements = {}

        for _, element in ipairs(api.nvim_buf_get_lines(buffer, 0, -1, false)) do
            if element ~= '' and not utils.starts_with(element, '#') then
                if utils.ends_with(element, utils.path_separator) then
                    -- remove trailing path separator for directories
                    element = element:sub(1, #element - 1)
                end

                if luv.fs_access(element, 'r') then
                    table.insert(buf_elements, element)
                end
            end
        end

        table.sort(buf_elements)

        if table.concat(elements) ~= table.concat(buf_elements) then
            vim.cmd('redraw')
            local apply_changes = vim.fn.confirm('Should your changes be applied?', '&Yes\n&No', 1) == 1

            if apply_changes then
                local tmp_clipboard = {}
                for _, element in ipairs(buf_elements) do
                    tmp_clipboard[element] = true
                end
                M.clipboard = tmp_clipboard

                reload_drex_syntax()
            end
        end

        vim.schedule(function()
            if api.nvim_win_is_valid(clipboard_win) then
                api.nvim_win_close(clipboard_win, true)
            end
        end)

        buffer_autocmds[buffer] = nil
    end

    vim.cmd(table.concat({
        'augroup DrexClipboardBuffer',
            'autocmd! * <buffer>',
            'autocmd WinLeave,BufUnload <buffer> lua require("drex.actions").call_buf_autocmd(' .. buffer .. ')',
        'augroup END',
    }, '\n'))
end

---Clear the clipboard and reload the DREX syntax
function M.clear_clipboard()
    M.clipboard = {}
    reload_drex_syntax()
end

---Mark the elements from `startRow` to `endRow` and add them to the DREX clipboard
---If not both parameters are provided use the current line as default
---@param startRow number
---@param endRow number
function M.mark(startRow, endRow)
    if not startRow or not endRow then
        startRow = api.nvim_win_get_cursor(0)[1]
        endRow = api.nvim_win_get_cursor(0)[1]
    end

    for row = startRow, endRow, 1 do
        local element = utils.get_element(vim.fn.getline(row))
        M.clipboard[element] = true
    end

    reload_drex_syntax()
end

---Unmark the elements from `startRow` to `endRow` and remove them from the DREX clipboard
---If not both parameters are provided use the current line as default
---@param startRow number
---@param endRow number
function M.unmark(startRow, endRow)
    if not startRow or not endRow then
        startRow = api.nvim_win_get_cursor(0)[1]
        endRow = api.nvim_win_get_cursor(0)[1]
    end

    for row = startRow, endRow, 1 do
        local element = utils.get_element(vim.fn.getline(row))
        M.clipboard[element] = nil
    end

    reload_drex_syntax()
end

---Toggle the elements from `startRow` to `endRow`
---- A marked row will be unmarked and removed from the DREX clipboard
---- An unmarked row will be marked and added to the DREX clipboard
---If not both parameters are provided use the current line as default
---@param startRow number
---@param endRow number
function M.toggle(startRow, endRow)
    if not startRow or not endRow then
        startRow = api.nvim_win_get_cursor(0)[1]
        endRow = api.nvim_win_get_cursor(0)[1]
    end

    for row = startRow, endRow, 1 do
        local element = utils.get_element(vim.fn.getline(row))
        M.clipboard[element] = not M.clipboard[element] or nil
    end

    reload_drex_syntax()
end

-- ####################################
-- ### file action related functions
-- ####################################

---Copy and paste all DREX clipboard entries to the current location
function M.copy_and_paste()
    paste(false)
end

---Cut and move all DREX clipboard entries to the current location
function M.cut_and_move()
    paste(true)
end

---Rename `old_element` to `new_element`
---@param old_element string
---@param new_element string
---@return boolean success
---@return string error
local function rename_element(old_element, new_element)
    if old_element == new_element then
        return false
    end

    local stats = luv.fs_stat(new_element)
    if stats then
        if stats.type == 'directory' then
            local data, error = luv.fs_scandir(new_element)
            if error then
                return false, error
            end

            local item = luv.fs_scandir_next(data)
            if item then
                return false, new_element .. ' is a non-empty directory. You have to manually check this!'
            end
        end

        if vim.fn.confirm(new_element .. ' already exists. Overwrite?', '&Yes\n&No', 2) == 1 then
            return false
        end
    end

    create_directories(new_element)
    local _, error = luv.fs_rename(old_element, new_element)

    if error then
        return false, error
    end

    rename_loaded_buffers(old_element, new_element)
    return true
end

---Rename multiple elements in a separate buffer
---- 'clipboard': rename all elements from the DREX clipboard
---- 'visual': rename all elements in the current visual selection
---- 'line': (default) rename the element in the current line
---
---Some important notes:
---- The renaming is executed once you close the buffer (you will be asked to confirm)
---- The renaming happens in the order of the elements within the buffer
---@param mode string The rename mode to use
function M.multi_rename(mode)
    local elements

    if mode == 'clipboard' then
        elements = get_clipboard_entries('desc')
        if #elements == 0 then
            vim.notify('The clipboard is empty! There is nothing to rename...', vim.log.levels.INFO, { title = 'DREX' })
            return
        end
    elseif mode == 'visual' then
        elements = {}
        local startRow, endRow = visual_selected_rows()
        for row = startRow, endRow, 1 do
            table.insert(elements, utils.get_element(vim.fn.getline(row)))
        end
        table.sort(elements, function(a, b) return a > b end) -- sort descending
    else
        elements = { utils.get_element(api.nvim_get_current_line()) }
    end

    local buffer_lines = {
        "# Confirm changes by leaving this buffer or closing the window and approve the",
        "# confirmation (only if changes exist). Renaming will be processed line by line",
        "# from top to bottom. Comment lines starting with '#' will be ignored",
        unpack(elements)
    }

    local buffer = api.nvim_create_buf(false, true)
    api.nvim_buf_set_lines(buffer, 0, -1, false, buffer_lines)
    api.nvim_buf_set_option(buffer, 'buftype', 'nofile')
    api.nvim_buf_set_option(buffer, 'bufhidden', 'wipe')
    api.nvim_buf_set_option(buffer, 'syntax', 'gitcommit') -- to shade comment lines
    api.nvim_buf_set_name(buffer, 'DREX Rename')
    buf_clear_undo_history(buffer)

    vim.cmd('below split')
    api.nvim_set_current_buf(buffer)

    buffer_autocmds[buffer] = function()
        local buf_elements = vim.tbl_filter(
            function(line) return not utils.starts_with(line, "#") end, -- filter out comment lines
            api.nvim_buf_get_lines(buffer, 0, -1, false))

        if table.concat(elements) ~= table.concat(buf_elements) then
            vim.cmd('redraw')
            local confirm = vim.fn.confirm('Should your changes be applied?', '&Yes\n&No\n&Diff', 2)

            if confirm == 3 then
                local diff = {}
                for index, old_element in ipairs(elements) do
                    local new_element = buf_elements[index]
                    if old_element ~= new_element then
                        table.insert(diff, old_element .. ' --> ' .. new_element)
                    end
                end

                -- increase `cmdheight` to prevent "hit enter prompt"
                local cmd_height = vim.opt.cmdheight:get()
                if cmd_height < #diff + 1 then
                    vim.opt.cmdheight = #diff + 1
                end

                vim.cmd('redraw')
                utils.echo(table.concat(diff, '\n'), false, 'WarningMsg')
                confirm = vim.fn.confirm('Should your changes be applied?', '&Yes\n&No', 2)

                vim.opt.cmdheight = cmd_height
            end

            local renamed_counter = 0

            if confirm == 1 then
                for index, old_element in ipairs(elements) do
                    local new_element = buf_elements[index]
                    if old_element ~= new_element then
                        local _, error = rename_element(old_element, new_element)
                        if error then
                            vim.cmd('redraw')
                            utils.echo(error, false, 'ErrorMsg')
                            if index < #elements and vim.fn.confirm('Continue?', '&Yes\n&No', 1) ~= 1 then
                                return
                            end
                        else
                            renamed_counter = renamed_counter + 1

                            if mode == 'clipboard' then
                                M.clipboard[old_element] = nil
                                M.clipboard[new_element] = true
                            end
                        end
                    end
                end

                if renamed_counter > 0 then
                    vim.cmd('redraw')
                    local msg = 'Renamed ' .. renamed_counter .. ' element' .. (renamed_counter > 1 and 's' or '')
                    -- scheduling is needed inside autocommand call to avoid issues with `vim-notify`
                    vim.schedule(function() vim.notify(msg, vim.log.levels.INFO, { title = 'DREX' }) end)
                end
            end
        end

        buffer_autocmds[buffer] = nil
    end

    vim.cmd(table.concat({
        'augroup DrexRenameBuffer',
            'autocmd! * <buffer>',
            'autocmd BufUnload <buffer> lua require("drex.actions").call_buf_autocmd(' .. buffer .. ')',
        'augroup END',
    }, '\n'))
end

---Rename the element under the cursor
---The path of the renamed element can be changed and new directories will be created automatically
function M.rename()
    local old_element = utils.get_element(api.nvim_get_current_line())
    local new_element = vim.fn.input('New name: ', old_element)

    if new_element == '' then
        return
    end
    vim.cmd('redraw') -- clear input area

    local success, error = rename_element(old_element, new_element)

    if success then
        if M.clipboard[old_element] then
            M.clipboard[old_element] = nil
            M.clipboard[new_element] = true
            reload_drex_syntax()
        end

        -- if the renamed element is in scope of the current DREX buffer, focus it
        if utils.starts_with(new_element, utils.get_root_path(0)) then
            local window = api.nvim_get_current_win()
            local focus_fn = function() require('drex').focus_element(window, new_element) end

            if not fs.post_next_reload(
                vim.fn.fnamemodify(new_element, ':h') .. utils.path_separator,
                api.nvim_get_current_buf(),
                focus_fn)
            then
                focus_fn()
            end
        end
    else
        vim.notify("Could not rename '" .. old_element .. "':\n" .. error, vim.log.levels.ERROR, { title = 'DREX' })
    end
end

---Create a new element (file or directory)
---Nonexistent directories of the new path will be created as well
function M.create()
    local dest_path = get_destination_path()
    if not dest_path then
        return
    end

    local new_element = vim.fn.input('New file/directory: ', dest_path, 'dir')

    -- if users cancels input (e.g. via 'esc') the return value is also empty
    if new_element == '' then
        return
    end

    local existing_base_path = create_directories(new_element)[1]

    -- check if only directories should be created
    if not utils.ends_with(new_element, utils.path_separator) then
        -- check if a file with this name already exists
        if luv.fs_stat(new_element) then
            local action = vim.fn.confirm(new_element .. ' already exists. Overwrite?', '&Yes\n&No', 2)
            if action ~= 1 then
                return
            end
        end

        local mode = luv.constants.O_CREAT + luv.constants.O_WRONLY + luv.constants.O_TRUNC
        local fd, error = luv.fs_open(new_element, 'w', mode)
        if error then
            vim.notify("Could not create file '" .. new_element .. "':\n" .. error, vim.log.levels.ERROR, { title = 'DREX' })
            return
        end

        -- libuv creates files with executable permissions (1101)
        -- therefore chmod the result to default permissions ('rw-r--r--')
        luv.fs_chmod(new_element, 420)
        luv.fs_close(fd)
    end

    -- if the newly created element is in scope of the current DREX buffer, focus it
    if utils.starts_with(new_element, utils.get_root_path(0)) then
        local window = api.nvim_get_current_win()
        local focus_fn = function() require('drex').focus_element(window, new_element) end

        if not fs.post_next_reload(existing_base_path, api.nvim_get_current_buf(), focus_fn) then
            focus_fn()
        end
    end
end

---Delete one or more elements depending on the given `mode`:
---- 'clipboard': delete all DREX clipboard entries
---- 'visual': delete all elements in the current visual selection
---- 'line': (default) delete the element in the current line
---
---Returns `true` if all elements were successfully deleted
---@param mode string The delete mode to use
---@return boolean
function M.delete(mode)
    local elements

    -- for 'visual' and 'line' highlight the elements which are about to be deleted
    local matches = {}
    local clear_matches = function()
        if vim.tbl_count(matches) > 0 then
            for _, match in ipairs(matches) do
                vim.fn.matchdelete(match)
            end
        end
    end

    if mode == 'clipboard' then
        elements = get_clipboard_entries('asc')
        if #elements == 0 then
            vim.notify('The clipboard is empty! There is nothing to delete...', vim.log.levels.INFO, { title = 'DREX' })
            return true
        end
        utils.echo('[CLIPBOARD DELETE]')
    elseif mode == 'visual' then
        elements = {}
        local startRow, endRow = visual_selected_rows()
        for row = startRow, endRow, 1 do
            local element = utils.get_element(vim.fn.getline(row))
            table.insert(elements, element)
            table.insert(matches, vim.fn.matchadd('WarningMsg', utils.vim_escape(element) .. '\\($\\|/.*\\)$'))
        end
        vim.cmd('redraw')
    else
        -- if nothing is selected, use current line instead
        elements = { utils.get_element(api.nvim_get_current_line()) }
        table.insert(matches, vim.fn.matchadd('WarningMsg', utils.vim_escape(elements[1]) .. '\\($\\|/.*\\)$'))
        vim.cmd('redraw')
    end

    -- confirm to delete selected element(s)
    local prompt = 'Should the following elements really be deleted?\n' .. table.concat(elements, '\n')
    local action = vim.fn.confirm(prompt, '&Yes\n&No', 2)
    if action ~= 1 then
        clear_matches()
        return false
    end

    -- for multiple entries reverse the order to delete more specific paths first
    -- for the confirm prompt an alphabetical order is used for better readability
    if #elements > 1 then
        table.sort(elements, function(a, b) return a > b end)
    end

    local delete_counter = 0

    for index, element in ipairs(elements) do
        local error
        if luv.fs_stat(element).type == 'directory' then
            error = delete_directory(element)
        else
            _, error = luv.fs_unlink(element)
        end

        if error then
            utils.echo("Could not delete '" .. element .. "':\n" .. error, false, 'ErrorMsg')
            if index < #elements then
                if vim.fn.confirm('Continue?', '&Yes\n&No', 1) == 1 then
                    goto continue
                else
                    clear_matches()
                    reload_drex_syntax()
                    return false
                end
            end
        end

        delete_counter = delete_counter + 1
        M.clipboard[element] = nil

        -- delete corresponding (and loaded) buffer
        for _, buf in ipairs(api.nvim_list_bufs()) do
            if api.nvim_buf_is_loaded(buf) then
                if utils.starts_with(api.nvim_buf_get_name(buf), element) then
                    api.nvim_buf_delete(buf, { force = true })
                end
            end
        end

        ::continue::
    end

    vim.notify('Deleted ' .. delete_counter .. ' element' .. (delete_counter > 1 and 's' or ''), vim.log.levels.INFO, { title = 'DREX' })
    clear_matches()
    reload_drex_syntax()
    return true
end

---Print file/directory details for the current element
--- - created, accessed and modified time
--- - file size
--- - permissions
function M.stats()
    utils.check_if_drex_buffer(0)

    local element = utils.get_element(api.nvim_get_current_line())
    local details = luv.fs_stat(element)

    if not details then
        vim.notify("Could not read details for '" .. element .. "'!", vim.log.levels.ERROR, { title = 'DREX' })
        return
    end

    local created  = os.date('%c', details.birthtime.sec)
    local accessed = os.date('%c', details.atime.sec)
    local modified = os.date('%c', details.mtime.sec)

    -- convert file/directory size in bytes into human readable format (SI)
    -- source: https://stackoverflow.com/a/3758880
    local size
    local bytes = details.size
    if details.size > -1000 and details.size < 1000 then
        size = bytes .. 'B'
    else
        local index = 1
        -- kilo, mega, giga, tera, peta, exa
        local prefixes = { 'k', 'M', 'G', 'T', 'P', 'E' }
        while bytes <= -999950 or bytes >= 999950 do
            bytes = bytes / 1000
            index = index + 1
        end
        size = string.format('%.1f%sB', bytes / 1000, prefixes[index])
    end

    -- format positive byte size with decimal delimiters
    -- e.g. 123456789 --> 123,456,789
    -- source: https://stackoverflow.com/a/11005263
    local formatted_byte_size = tostring(details.size):reverse():gsub("%d%d%d", "%1,"):reverse():gsub("^,", "")

    -- mask off the file type portion of mode (using 07777)
    -- print as octal number to see the real permissions
    local mode = string.format('%o', bit.band(details.mode, tonumber('07777', 8)))

    -- cycle through the mode digits to extract the access permissions (read, write & execute)
    -- for every class (user, group & others) into a single human readable string
    -- for example:
    -- --> mode = 664
    -- --> access_permissions = rw-rw-r--
    local access_permissions = ''
    for c in mode:gmatch('.') do
        local num = tonumber(c)
        local class = ''

        -- check for "read" access
        if (num - 4) >= 0 then
            class = class .. 'r'
            num = num - 4
        else
            class = class .. '-'
        end

        -- check for "write" access
        if (num - 2) >= 0 then
            class = class .. 'w'
            num = num - 2
        else
            class = class .. '-'
        end

        -- check for "execute" access
        if (num - 1) >= 0 then
            class = class .. 'x'
            num = num - 1
        else
            class = class .. '-'
        end

        access_permissions = access_permissions .. class
    end

    utils.echo(table.concat({
        'Details for ' .. details.type .. " '" .. element .. "'",
        ' ',
        'Size:         ' .. size .. ' (' .. formatted_byte_size .. ' bytes)',
        'Permissions:  ' .. access_permissions .. ' (' .. mode .. ')',
        'Created:      ' .. created,
        'Accessed:     ' .. accessed,
        'Modified:     ' .. modified,
    }, '\n'))
end

-- ####################################
-- ### string copy functions
-- ####################################

---Helper function to copy element string to the clipboard
---@param selection boolean If `true` use the last selection, if `false` only operate on the current line
---@param extract_fn function Function that should be used to extract the desired string value to copy
local function copy_element_strings(selection, extract_fn)
    local lines = {}
    if selection then
        local startRow, endRow = visual_selected_rows()
        for row = startRow, endRow, 1 do
            table.insert(lines, extract_fn(vim.fn.getline(row)))
        end
        vim.notify('Copied ' .. (endRow - startRow + 1) .. ' values to text clipboard', vim.log.levels.INFO, { title = 'DREX' })
    else
        local line_value = extract_fn(api.nvim_get_current_line())
        table.insert(lines, line_value)
        vim.notify("Copied '" .. line_value .. "' to text clipboard", vim.log.levels.INFO, { title = 'DREX' })
    end

    local value = table.concat(lines, '\n')

    -- use "charwise" for single lines
    -- use "linewise" for visual selections
    local mode = selection and 'l' or 'c'

    vim.fn.setreg('"', value, mode)
    vim.fn.setreg('*', value, mode)
    vim.fn.setreg('+', value, mode)
end

---Copy the element name
---@param selection boolean Indicator if called from visual mode (if so use last selection)
function M.copy_element_name(selection)
    utils.check_if_drex_buffer(0)
    copy_element_strings(selection, utils.get_name)
end

---Copy the elements path relative to the current root path
---@param selection boolean Indicator if called from visual mode (if so use last selection)
function M.copy_element_relative_path(selection)
    utils.check_if_drex_buffer(0)
    local root_path = utils.get_root_path(0)
    copy_element_strings(selection, function(str)
        local name = utils.get_name(str)
        local path = utils.get_path(str)
        local rel_path = path:gsub(utils.escape(root_path), '')
        return rel_path .. name
    end)
end

---Copy the absolute elements path
---@param selection boolean Indicator if called from visual mode (if so use last selection)
function M.copy_element_absolute_path(selection)
    utils.check_if_drex_buffer(0)
    copy_element_strings(selection, utils.get_element)
end

return M
