local Blitbuffer = require("ffi/blitbuffer")
local ButtonDialog = require("ui/widget/buttondialog")
local ButtonTable = require("ui/widget/buttontable")
local DataStorage = require("datastorage")
local Device = require("device")
local Event = require("ui/event")
local EventListener = require("ui/widget/eventlistener")
local FrameContainer = require("ui/widget/container/framecontainer")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local LuaSettings = require("luasettings")
local Screen = Device.screen
local Size = require("ui/size")
local SpinWidget = require("ui/widget/spinwidget")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")
local T = require("ffi/util").template
local ffiutil = require("ffi/util")
local http = require("socket.http")
local logger = require("logger")
local ltn12 = require("ltn12")
local rapidjson = require("rapidjson")
local util = require("util")

-- Sibling modules of this plugin folder
local _dir = debug.getinfo(1, "S").source:match("^@(.*/)[^/]*$") or "./"
local TextParser = dofile(_dir .. "textparser.lua")
local SentenceHighlight = dofile(_dir .. "sentencehighlight.lua")

---@class TTS:WidgetContainer
local TTS = WidgetContainer:extend({
    name = "name of tts widget",
    fullname = _("fullname of tts widget"),
    settings = nil, -- nil means uninit widget
    luasettings = nil, -- nil means uninit widget
    prev_item = nil, -- nil means current_item is the first possible
    next_item = nil, -- nil means current_item is the last possible
    current_item = nil, -- nil means tts is not started
    widget = nil, -- nil means tts is not started
    playing_promise = nil, -- nil means not playing rn
    highlighter = nil, -- sentence overlay highlighter, created on start
    _block_cache = nil, -- parsed blocks cache, key = block pos0 xpointer
    _block_cache_keys = nil, -- LRU order of _block_cache
})

-- Max blocks kept in the cache (prev/current/next and a margin)
local BLOCK_CACHE_MAX = 6
-- Max consecutive empty blocks skipped while navigating
local MAX_EMPTY_SKIPS = 25

function TTS:init()
    if not self.luasettings then
        self:readSettingsFile()
    end
    self.ui.menu:registerToMainMenu(self)
end

function TTS:readSettingsFile()
    self.luasettings = LuaSettings:open(DataStorage:getSettingsDir() .. "/tts.lua")
    self.settings = {}
    -- Overlay style. Legacy values from the original plugin ("lighten",
    -- annotation drawers) map to the closest overlay style.
    local drawer = self.luasettings:readSetting("highlight_style.drawer", "invert")
    if drawer ~= "invert" and drawer ~= "underline" and drawer ~= "box"
        and drawer ~= "background" then
        drawer = "background" -- "lighten" and anything unknown
    end
    self.settings.drawer = drawer
    self.settings.hostname = self.luasettings:readSetting("hostname", "localhost:5000")
    self.settings.server_extra_args = self.luasettings:readSetting("server_extra_args", {})
    self:settings_flush()
end

function TTS:settings_flush()
    -- Snapshot of the settings that invalidate already-generated audio
    local audio_relevant = {
        voice = self.settings.server_extra_args.voice,
        length_scale = self.settings.server_extra_args.length_scale,
        volume = self.settings.server_extra_args.volume,
    }
    local prev_audio = self._audio_settings_snapshot
    local audio_changed = prev_audio ~= nil and (
        prev_audio.voice ~= audio_relevant.voice
        or prev_audio.length_scale ~= audio_relevant.length_scale
        or prev_audio.volume ~= audio_relevant.volume
    )
    self._audio_settings_snapshot = audio_relevant

    self.luasettings:saveSetting("highlight_style.drawer", self.settings.drawer)
    self.luasettings:saveSetting("hostname", self.settings.hostname)
    self.luasettings:saveSetting("server_extra_args", self.settings.server_extra_args)
    self.luasettings:flush()
    if self.highlighter then
        self.highlighter:setStyle(self.settings.drawer)
    end
    if self.current_item ~= nil then
        if audio_changed then
            -- Settings changed the audio: discard cached wavs around us
            for _, item in ipairs({ self.prev_item, self.current_item, self.next_item }) do
                if item ~= nil and item.wav ~= nil then
                    item.wav = nil
                    if item.wav_promise ~= nil then
                        item.wav_promise:cancel()
                    end
                end
            end
        end
        -- Redraw with the (possibly new) highlight style
        self:change_highlight(self.current_item)
    end
end

function TTS:onCloseDocument()
    logger.dbg("TTS: onCloseDocument")
    self:stop_tts_mode()
end

function TTS:onCloseWidget()
    logger.dbg("TTS: onCloseWidget")
    self:settings_flush()
end

function TTS:addToMainMenu(menu_items)
    if not self.ui.document then -- only add in reader view
        return
    end
    menu_items.tts_plugin = {
        sorting_hint = "typeset",
        text = _("Start TTS Mode"),
        callback = function()
            self:start_tts_mode()
        end,
    }
end

function TTS:start_tts_mode()
    self._block_cache = {}
    self._block_cache_keys = {}
    self.highlighter = SentenceHighlight:new({
        ui = self.ui,
        plugin = self,
        style = self.settings.drawer,
    })
    self.current_item = self:_first_at_current_pos()
    if self.current_item == nil then
        self.highlighter = nil
        UIManager:show(InfoMessage:new({ text = _("No more text to read from here") }))
        return
    end
    self.next_item = self:item_next(self.current_item)
    self.prev_item = self:item_prev(self.current_item)
    self:show_widget()
    self:change_highlight(self.current_item)
end

function TTS:stop_tts_mode()
    self:stop_playing()
    if self.highlighter then
        self.highlighter:clearHighlights()
        self.highlighter = nil
    end
    self.next_item = nil
    self.prev_item = nil
    if self.widget then
        UIManager:close(self.widget)
    end
    self.widget = nil
end

---------------- sentence highlighting (overlay, no annotations) --------------

function TTS:change_highlight(item)
    self.current_item = item
    if self.highlighter == nil then
        return
    end
    local drawn = self.highlighter:drawSentence(item)
    if not drawn then
        -- Sentence not visible: bring its block's page into view, retry once
        self.ui:handleEvent(Event:new("GotoXPointer", item.pos0))
        self.highlighter:drawSentence(item)
    end
end

---------------- block parsing: xpointers -> sentences --------------

-- Compute the block (paragraph) start xpointer of a given xpointer.
function TTS:xpointer_start(xpointer)
    local wrap = self.ui.document.configurable.text_wrap
    self.ui.document.configurable.text_wrap = 0
    local page = self.ui.document:getPageFromXPointer(xpointer)
    local prefix = xpointer:match("^(.*)%.[^%.]*$")
    if not prefix then
        prefix = xpointer
    end
    local start = prefix .. ".0"
    if self.ui.view.view_mode == "page" and page ~= self.ui.document:getPageFromXPointer(start) then
        self.ui.document.configurable.text_wrap = wrap
        return self.ui.document:getPageXPointer(page)
    end
    self.ui.document.configurable.text_wrap = wrap
    return start
end

-- Compute the block (paragraph) end xpointer of a given xpointer
-- (binary search over the numeric offsets the xpointer supports).
function TTS:xpointer_end(xpointer)
    local wrap = self.ui.document.configurable.text_wrap
    self.ui.document.configurable.text_wrap = 0
    local page = self.ui.document:getPageFromXPointer(xpointer)
    local prefix = xpointer:match("^(.*)%.[^%.]*$")
    if not prefix then
        prefix = xpointer
    end
    prefix = prefix .. "."
    local node_text = self.ui.document:getTextFromXPointer(xpointer) or ""
    local max = node_text:len() * 2
    local min = 1
    while min < max do
        local mid = math.floor((min + max) / 2)
        local mid_text = self.ui.document:getTextFromXPointer(prefix .. mid) or ""
        if
            #mid_text ~= 0
            and (self.ui.view.view_mode ~= "page"
                or page >= self.ui.document:getPageFromXPointer(prefix .. mid))
        then
            min = mid + 1
        else
            max = mid
        end
    end
    self.ui.document.configurable.text_wrap = wrap
    return prefix .. min - 1
end

-- Parse the block containing `xpointer` into sentence items.
-- Items carry the BLOCK xpointers (for page navigation) plus the
-- sentence text (for TTS and overlay matching). Cached by block pos0.
function TTS:block_items(xpointer)
    local ok, pos0 = pcall(self.xpointer_start, self, xpointer)
    if not ok or not pos0 then
        return nil
    end
    local key = pos0
    local cached = self._block_cache and self._block_cache[key]
    if cached then
        self:_block_cache_touch(key)
        return cached
    end
    local ok_end, pos1 = pcall(self.xpointer_end, self, xpointer)
    if not ok_end or not pos1 then
        return nil
    end
    local text = self.ui.document:getTextFromXPointers(pos0, pos1)
    if text ~= nil then
        text = util.cleanupSelectedText(text)
    else
        text = ""
    end
    local parsed = TextParser:parse(text)
    local items = {}
    for i, sentence in ipairs(parsed.sentences) do
        table.insert(items, {
            pos0 = pos0,
            pos1 = pos1,
            text = sentence.text,
            s_idx = i,
            s_count = #parsed.sentences,
        })
    end
    local block = { pos0 = pos0, pos1 = pos1, items = items }
    self:_block_cache_store(key, block)
    return block
end

function TTS:_block_cache_touch(key)
    for i, k in ipairs(self._block_cache_keys or {}) do
        if k == key then
            table.remove(self._block_cache_keys, i)
            table.insert(self._block_cache_keys, key)
            return
        end
    end
end

function TTS:_block_cache_store(key, block)
    if not self._block_cache then
        self._block_cache = {}
    end
    if not self._block_cache_keys then
        self._block_cache_keys = {}
    end
    self._block_cache[key] = block
    table.insert(self._block_cache_keys, key)
    while #self._block_cache_keys > BLOCK_CACHE_MAX do
        local evict = table.remove(self._block_cache_keys, 1)
        self._block_cache[evict] = nil
    end
end

-- First sentence of the first non-empty block starting at `xpointer`.
function TTS:_first_sentence_of_block(xpointer)
    for _ = 1, MAX_EMPTY_SKIPS do
        local block = self:block_items(xpointer)
        if block and #block.items > 0 then
            return block.items[1]
        end
        local nxp = self.ui.document:getNextVisibleChar(block and block.pos1 or xpointer)
        if nxp == nil then
            return nil
        end
        xpointer = nxp
    end
    return nil
end

-- Last sentence of the last non-empty block before `xpointer`.
function TTS:_last_sentence_of_block(xpointer)
    for _ = 1, MAX_EMPTY_SKIPS do
        local block = self:block_items(xpointer)
        if block and #block.items > 0 then
            return block.items[#block.items]
        end
        local pxp = self.ui.document:getPrevVisibleChar(block and block.pos0 or xpointer)
        if pxp == nil then
            return nil
        end
        xpointer = pxp
    end
    return nil
end

-- First sentence of the block of the first visible char of the current page.
function TTS:_first_at_current_pos()
    local xpointer = self.ui.document:getPageXPointer(self.ui.document:getCurrentPage(true))
    local s = self.ui.document:getNextVisibleChar(xpointer)
    if s ~= nil then
        xpointer = s
    end
    return self:_first_sentence_of_block(xpointer)
end

-- Next sentence: within the block first, then first sentence of next block.
function TTS:item_next(item)
    if item == nil then
        return nil
    end
    local block = self:block_items(item.pos0)
    if block and item.s_idx < #block.items then
        return block.items[item.s_idx + 1]
    end
    local nxp = self.ui.document:getNextVisibleChar(item.pos1)
    if nxp == nil then
        return nil
    end
    return self:_first_sentence_of_block(nxp)
end

-- Previous sentence: within the block first, then last sentence of prev block.
function TTS:item_prev(item)
    if item == nil then
        return nil
    end
    local block = self:block_items(item.pos0)
    if block and item.s_idx > 1 then
        return block.items[item.s_idx - 1]
    end
    local pxp = self.ui.document:getPrevVisibleChar(block and block.pos0 or item.pos0)
    if pxp == nil then
        return nil
    end
    return self:_last_sentence_of_block(pxp)
end

------------------------- THE WIDGET -------------------------

function TTS:show_widget()
    local screen_w = Screen:getWidth()
    local screen_h = Screen:getHeight()
    local widget
    widget = FrameContainer:new({
        radius = Size.radius.window,
        bordersize = Size.border.window,
        padding = 0,
        margin = 0,
        background = Blitbuffer.COLOR_WHITE,
        ButtonTable:new({
            buttons = {
                {
                    {
                        text = "⚙",
                        callback = function()
                            if self.playing_promise ~= nil then
                                self:stop_playing()
                                UIManager:close(widget)
                                self:show_widget()
                            end
                            self:show_settings()
                        end,
                    },
                    {
                        text = "◁",
                        callback = function()
                            local was_playing = self.playing_promise ~= nil
                            self:stop_playing()
                            if self.next_item ~= nil and self.next_item.wav_promise ~= nil then
                                self.next_item.wav_promise:cancel()
                            end
                            self.next_item = self.current_item
                            self:change_highlight(self.prev_item or self.current_item)
                            self.prev_item = self:item_prev(self.prev_item)
                            if was_playing then
                                self:start_playing()
                            end
                        end,
                    },
                    {
                        text_func = function()
                            if self.playing_promise ~= nil then
                                return "⏸"
                            end
                            return "⏵"
                        end,
                        callback = function()
                            if self.playing_promise ~= nil then
                                self:stop_playing()
                            else
                                self:start_playing()
                            end
                            UIManager:close(widget)
                            self:show_widget()
                        end,
                    },
                    {
                        text = "▷",
                        callback = function()
                            local was_playing = self.playing_promise ~= nil
                            self:stop_playing()
                            if self.prev_item ~= nil and self.prev_item.wav_promise ~= nil then
                                self.prev_item.wav_promise:cancel()
                            end
                            self.prev_item = self.current_item
                            self:change_highlight(self.next_item or self.current_item)
                            self.next_item = self:item_next(self.next_item)
                            if was_playing then
                                self:start_playing()
                            end
                        end,
                    },
                    {
                        text = "⏹",
                        callback = function()
                            self:stop_tts_mode()
                        end,
                    },
                },
            },
        }),
    })
    local size = widget:getSize()
    self.widget = widget
    UIManager:show(widget, nil, nil, math.floor((screen_w - size.w) / 2), screen_h - size.h - 27)
end

local function pairsByKeys(t, f)
    local a = {}
    for n in pairs(t) do
        table.insert(a, n)
    end
    table.sort(a, f)
    local i = 0 -- iterator variable
    local iter = function() -- iterator function
        i = i + 1
        if a[i] == nil then
            return nil
        else
            return a[i], t[a[i]]
        end
    end
    return iter
end
function TTS:show_settings()
    local settings_dialog
    settings_dialog = ButtonDialog:new({
        title = _("TTS settings"),
        buttons = {
            {
                {
                    text = _("Speed"),
                    callback = function()
                        UIManager:show(SpinWidget:new({
                            value = self.settings.server_extra_args.length_scale,
                            value_min = 0.01,
                            value_max = 3,
                            precision = "%.2f",
                            value_step = 0.01,
                            value_hold_step = 0.1,
                            default_value = 1,
                            title_text = _("Length scale"),
                            info_text = _("A value of 2 means that audio will take twice the time to play"),
                            callback = function(spin)
                                self.settings.server_extra_args.length_scale = spin.value
                                self:settings_flush()
                            end,
                        }))
                    end,
                },
                {
                    text = _("Volume"),
                    callback = function()
                        UIManager:show(SpinWidget:new({
                            value = self.settings.server_extra_args.volume,
                            value_min = 0,
                            value_max = 1,
                            precision = "%.2f",
                            value_step = 0.01,
                            value_hold_step = 0.1,
                            default_value = 0.8,
                            title_text = _("Volume"),
                            info_text = _("Select volume from 0 to 1"),
                            callback = function(spin)
                                self.settings.server_extra_args.volume = spin.value
                                self:settings_flush()
                            end,
                        }))
                    end,
                },
            },
            {
                {
                    text = _("TTS server URL"),
                    callback = function()
                        UIManager:show(InputDialog:new({
                            title = _("Change TTS server URL"),
                            input_type = "text",
                            input = self.settings.hostname,
                            description = _("Don't add 'http://'"),
                            save_callback = function(new_hostname)
                                self.settings.hostname = new_hostname
                                self:settings_flush()
                            end,
                        }))
                    end,
                },
                {
                    text = _("Voice"),
                    callback = function()
                        local voices = self:server_get_voices()
                        if voices == nil then
                            UIManager:show(InfoMessage:new({ text = _("Could not fetch availible voices") }))
                            return
                        end
                        local upper_widget
                        local buttons = { {} }
                        for locale, cluster in pairsByKeys(voices) do
                            local last = buttons[#buttons]
                            if #last >= 6 then
                                last = {}
                                table.insert(buttons, last)
                            end
                            table.insert(last, {
                                text = locale,
                                callback = function()
                                    local voice_buttons = {}
                                    for _, voice in ipairs(cluster) do
                                        table.insert(voice_buttons, {
                                            {
                                                text = voice,
                                                checked = voice == self.settings.server_extra_args.voice,
                                                callback = function()
                                                    self.settings.server_extra_args.voice = voice
                                                    self:settings_flush()
                                                    UIManager:close(UIManager:getTopmostVisibleWidget())
                                                end,
                                            },
                                        })
                                    end
                                    table.insert(voice_buttons, {
                                        {
                                            text = _("Close"),
                                            callback = function()
                                                UIManager:close(UIManager:getTopmostVisibleWidget())
                                                UIManager:show(upper_widget())
                                            end,
                                        },
                                    })
                                    UIManager:close(UIManager:getTopmostVisibleWidget())
                                    UIManager:show(ButtonDialog:new({
                                        text = _("Select voice"),
                                        shrink_unneeded_width = true,
                                        buttons = voice_buttons,
                                    }))
                                end,
                            })
                        end
                        table.insert(buttons, {
                            {
                                text = _("Close"),
                                callback = function()
                                    UIManager:close(UIManager:getTopmostVisibleWidget())
                                end,
                            },
                        })
                        upper_widget = function()
                            return ButtonDialog:new({
                                title = self.settings.server_extra_args.voice
                                    and T(_('Current voice is "%1"'), self.settings.server_extra_args.voice)
                                    or _("Select voice"),
                                buttons = buttons,
                                shrink_unneeded_width = true,
                            })
                        end
                        UIManager:show(upper_widget())
                    end,
                },
            },
            {
                {
                    text = _("Highlight style"),
                    callback = function()
                        local styles = {
                            { id = "invert", name = _("Invert (best for e-ink)") },
                            { id = "underline", name = _("Underline") },
                            { id = "box", name = _("Box") },
                            { id = "background", name = _("Background") },
                        }
                        local style_buttons = { {} }
                        for _, s in ipairs(styles) do
                            table.insert(style_buttons[1], {
                                text = (self.settings.drawer == s.id and "✓ " or "") .. s.name,
                                callback = function()
                                    self.settings.drawer = s.id
                                    self:settings_flush()
                                    UIManager:close(UIManager:getTopmostVisibleWidget())
                                end,
                            })
                        end
                        table.insert(style_buttons, {
                            {
                                text = _("Close"),
                                callback = function()
                                    UIManager:close(UIManager:getTopmostVisibleWidget())
                                end,
                            },
                        })
                        UIManager:show(ButtonDialog:new({
                            title = _("Sentence highlight style"),
                            buttons = style_buttons,
                            shrink_unneeded_width = true,
                        }))
                    end,
                },
            },
            {
                {
                    text = _("Close"),
                    callback = function()
                        settings_dialog:onClose()
                        UIManager:close(settings_dialog)
                    end,
                },
            },
        },
    })

    UIManager:show(settings_dialog)
end

---------------- simple promises like in JS because we are doing some async and I don't know better ----------

---@class Promise:EventListener
local Promise = EventListener:extend({
    callbacks = nil, -- nil means resolved, an array (even empty) means pending
    on_cancel = nil,
})

function Promise:resolve()
    if self.callbacks == nil then
        return
    end
    for _, callback in ipairs(self.callbacks) do
        callback()
    end
    self.callbacks = nil
end

---@param callback fun()
function Promise:add_callback(callback)
    if self.callbacks == nil then
        callback()
        return
    end
    self.callbacks[#self.callbacks + 1] = callback
end

function Promise:cancel()
    self.callbacks = nil
    self.add_callback = function() end
    self.resolve = function() end
    if self.on_cancel ~= nil then
        self:on_cancel()
    end
    self.on_cancel = nil
end

function Promise.wait_repeatedly(time_estimate)
    local checker
    local promise = Promise.empty()
    checker = function()
        local time = time_estimate()
        if time ~= nil then
            UIManager:scheduleIn(time, checker)
        else
            promise:resolve()
        end
    end
    checker()
    return promise, function()
        UIManager:unschedule(checker)
    end
end

function Promise.wait_while(condition)
    return Promise.wait_repeatedly(function()
        if condition() then
            return 0.2
        else
            return nil
        end
    end)
end

function Promise.instant()
    return Promise:new({ callbacks = nil })
end

function Promise.empty()
    return Promise:new({ callbacks = {} })
end

function Promise:wrap()
    local promise = Promise.empty()
    self:add_callback(function()
        promise:resolve()
    end)
    return promise
end

------------------ AUDIO MODULE -------------------
function TTS:request_server(body, endpoint)
    if endpoint == nil then
        endpoint = ""
    end
    body = rapidjson.encode(body)
    local result = {}
    local a, code = http.request({
        method = "POST",
        url = "http://" .. self.settings.hostname .. endpoint,
        source = ltn12.source.string(body),
        headers = {
            ["Content-Length"] = #body,
            ["Content-Type"] = "application/json",
        },
        sink = ltn12.sink.table(result),
    })
    if a == 1 then
        return code, result
    end
    return 500, {}
end

function TTS:server_get_voices()
    local result = {}
    local a, code = http.request({
        url = "http://" .. self.settings.hostname .. "/voices",
        source = ltn12.source.empty(),
        sink = ltn12.sink.table(result),
    })
    if a ~= 1 or code ~= 200 then
        return nil
    end
    return rapidjson.decode(table.concat(result))
end

function TTS:play(item)
    local body = util.tableDeepCopy(self.settings.server_extra_args or {}) or {}
    body.handle = item.handle
    local code, _ = self:request_server(body, "/play")
    if code ~= 200 then
        logger.err("TTS: could not play. Is the TTS server down?")
        return Promise:instant()
    end
    local promise, unschedule = Promise.wait_repeatedly(function()
        local code2, responce_table = self:request_server(body, "/remaining")
        if code2 ~= 200 then
            logger.err("TTS: could not get remaining time. Is the TTS server down?")
            return 0.1
        end
        local est = rapidjson.decode(table.concat(responce_table))
        if not est.started then
            return 0.2
        end
        if est.remaining == 0 then
            return nil
        end
        return math.max(0.01, est.remaining - 0.2)
    end)

    local promise2 = promise:wrap()
    promise2.on_cancel = function()
        unschedule()
        local code2, _ = self:request_server(body, "/stop")
        if code2 ~= 200 then
            logger.err("TTS: could not stop playback. Is the TTS server down?")
        end
    end
    return promise2
end

---@return Promise
function TTS:ensure_handle_on_item(item)
    if item.handle_promise ~= nil then
        return item.handle_promise
    end

    local download_thread = function(_, write_pipe)
        local body = util.tableDeepCopy(self.settings.server_extra_args or {}) or {}
        body.text = item.text
        if body.text == nil or body.text == "" then
            body.text = "a"
        end
        local code, handle_table = self:request_server(body)
        if code == 200 then
            local handle = table.concat(handle_table)
            ffiutil.writeToFD(write_pipe, handle, true)
        else
            ffiutil.writeToFD(write_pipe, "ERR", true)
        end
    end
    local pid, read_pipe = ffiutil.runInSubProcess(download_thread, true)
    local promise, unschedule = Promise.wait_while(function()
        return not ffiutil.isSubProcessDone(pid)
    end)
    promise:add_callback(function()
        local handle = ffiutil.readAllFromFD(read_pipe)
        if handle == "ERR" then
            logger.err("TTS: could not generate wav file from text. Is the TTS server down?")
            if item.handle_promise ~= nil then
                item.handle_promise:cancel()
            end
        end
        item.handle_promise = nil
        item.handle = handle
    end)
    item.handle_promise = promise:wrap()
    item.handle_promise.on_cancel = function()
        unschedule()
        ffiutil.terminateSubProcess(pid)
        item.handle_promise = nil
        item.handle = nil
    end
    return item.handle_promise
end

function TTS:stop_playing()
    if self.playing_promise ~= nil then
        self.playing_promise:cancel()
        self.playing_promise = nil
    end
end

function TTS:start_playing()
    local loop_once
    loop_once = function()
        local wav_for_the_next
        if self.next_item ~= nil then
            wav_for_the_next = self:ensure_handle_on_item(self.next_item)
        end
        self.playing_promise = self:play(self.current_item)
        self.playing_promise:add_callback(function()
            if wav_for_the_next == nil then
                -- We hit the end of the book in tts mode
                self:stop_playing()
                UIManager:close(self.widget)
                self:show_widget()
                return
            end
            self.prev_item = self.current_item
            self:change_highlight(self.next_item)
            self.next_item = self:item_next(self.next_item)
            self.playing_promise = wav_for_the_next
            wav_for_the_next:add_callback(loop_once)
        end)
    end
    self.playing_promise = self:ensure_handle_on_item(self.current_item)
    self.playing_promise:add_callback(function()
        loop_once()
    end)
end

return TTS