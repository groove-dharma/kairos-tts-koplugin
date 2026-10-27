--[[--
Sentence Highlight Module (ported from stradichenko/audiobook.koplugin
highlightmanager, trimmed).

Draws a temporary overlay rectangle over the sentence currently being
read. Does NOT create annotations, does NOT touch KOReader's selection,
does NOT write anything to the document or its sidecar. EPUB (rolling)
only.

@module sentencehighlight
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Geom = require("ui/geometry")
local UIManager = require("ui/uimanager")

local Screen = Device.screen

--- Normalize text for matching: collapse whitespace, drop soft hyphens,
--- join line-wrap hyphenation. Applied to BOTH the sentence and the
--- on-screen line text so both sides follow the same rules.
local function normText(s)
    if not s then
        return ""
    end
    s = tostring(s)
    s = s:gsub("\xC2\xAD", "") -- soft hyphen U+00AD
    s = s:gsub("[%z\1-\8\11\12\14-\31]", "") -- C0 except \t \n \r
    s = s:gsub("\r\n", "\n")
    s = s:gsub("\r", "\n")
    s = s:gsub("([^%s%p])%-\n([^%s%p])", "%1%2") -- "re-\nduce" -> "reduce"
    s = s:gsub("%s+", " ")
    s = s:match("^%s*(.-)%s*$") or ""
    return s
end

--- Union of highlight box arrays, clamped to screen bounds.
local function boxesUnionRegion(arrays)
    local min_x, min_y, max_x, max_y
    for _, arr in ipairs(arrays) do
        if arr then
            for _, b in ipairs(arr) do
                local x2, y2 = b.x + b.w, b.y + b.h
                if not min_x or b.x < min_x then min_x = b.x end
                if not min_y or b.y < min_y then min_y = b.y end
                if not max_x or x2 > max_x then max_x = x2 end
                if not max_y or y2 > max_y then max_y = y2 end
            end
        end
    end
    if not min_x then
        return nil
    end
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    min_x = math.max(0, min_x)
    min_y = math.max(0, min_y)
    max_x = math.min(sw, max_x)
    max_y = math.min(sh, max_y)
    if max_x <= min_x or max_y <= min_y then
        return nil
    end
    return Geom:new({ x = min_x, y = min_y, w = max_x - min_x, h = max_y - min_y })
end

local SentenceHighlight = {
    STYLES = {
        INVERT = "invert",
        UNDERLINE = "underline",
        BOX = "box",
        BACKGROUND = "background",
    },
}

function SentenceHighlight:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self

    o.style = o.style or self.STYLES.INVERT
    o._view_module_registered = false
    -- Boxes of the highlight currently on screen (and their page), used to
    -- limit the next e-ink refresh to the changed strip only.
    o._last_boxes = nil
    o._last_boxes_page = nil
    o._pending_boxes = nil
    o._pending_view_page = nil
    o._pending_view_pos = nil
    o._line_cache = nil

    return o
end

--- Remember the document view the current overlay boxes belong to.
function SentenceHighlight:_captureViewForBoxes()
    local page, pos
    pcall(function()
        local doc = self.ui and self.ui.document
        if not doc then
            return
        end
        page = doc:getCurrentPage()
        if doc.getCurrentPos then
            pos = doc:getCurrentPos()
        end
    end)
    self._pending_view_page = page
    self._pending_view_pos = pos
end

--- False when the view has moved (page turn / scroll): screen-coordinate
--- boxes must not be stamped on the new view.
function SentenceHighlight:_boxesMatchCurrentView()
    if not self._pending_boxes then
        return false
    end
    local page, pos
    pcall(function()
        local doc = self.ui and self.ui.document
        if not doc then
            return
        end
        page = doc:getCurrentPage()
        if doc.getCurrentPos then
            pos = doc:getCurrentPos()
        end
    end)
    if self._pending_view_page ~= nil and page ~= nil
        and page ~= self._pending_view_page then
        return false
    end
    if self._pending_view_pos ~= nil and pos ~= nil
        and math.abs(pos - self._pending_view_pos) > 24 then
        return false
    end
    return true
end

--- Refresh only the screen strip covering previous + new highlight boxes.
function SentenceHighlight:_refreshHighlight(new_boxes, page)
    local arrays = {}
    if self._last_boxes and self._last_boxes_page == page then
        table.insert(arrays, self._last_boxes)
    end
    if new_boxes and #new_boxes > 0 then
        table.insert(arrays, new_boxes)
    end
    local region = boxesUnionRegion(arrays)
    if region then
        UIManager:setDirty(self.ui.dialog or "all", "ui", region)
    end
    self._last_boxes = new_boxes
    self._last_boxes_page = page
end

function SentenceHighlight:setStyle(style)
    self.style = style
end

--[[--
Draw the highlight for a sentence.

@param item table with .pos0/.pos1 (block xpointers), .text (sentence)
@return boolean true when the sentence was found and highlighted on the
        visible page
--]]
function SentenceHighlight:drawSentence(item)
    if not item or not self.ui or not self.ui.document then
        return false
    end
    if self.ui.paging then
        return false -- PDF: not supported (crengine xpointers are EPUB)
    end

    -- Drop previous highlight before searching for the new one
    self._pending_boxes = nil
    self._pending_view_page = nil
    self._pending_view_pos = nil

    local doc = self.ui.document
    local cur_w, cur_h = Screen:getWidth(), Screen:getHeight()
    local cur_page = doc:getCurrentPage() or 0

    -- ── Line map of the BLOCK, cached per page/screen ───────────
    local built_text, cum, sboxes, n
    local cache = self._line_cache
    if cache and cache.key == item.pos0
        and cache.screen_w == cur_w and cache.screen_h == cur_h
        and cache.page == cur_page then
        built_text = cache.built_text
        cum = cache.cum
        sboxes = cache.sboxes
        n = cache.n
    else
        local ok_boxes, boxes =
            pcall(doc.getScreenBoxesFromPositions, doc, item.pos0, item.pos1, true)
        if not ok_boxes or not boxes or #boxes == 0 then
            return false
        end
        sboxes = boxes
        n = #boxes

        -- Text of each visual line of the block (padded query so the
        -- first/last glyph is not clipped)
        local line_texts = {}
        local pad = 8
        for i = 1, n do
            local box = sboxes[i]
            local ok_line, r = pcall(doc.getTextFromPositions, doc,
                { x = math.max(0, box.x - pad), y = box.y + math.floor(box.h / 2) },
                { x = math.min(cur_w - 1, box.x + box.w - 1 + pad),
                  y = box.y + math.floor(box.h / 2) },
                true)
            line_texts[i] = (ok_line and r and r.text) and normText(r.text) or ""
        end

        -- Prefer the block's logical text as the base for matching (the
        -- sentences are partitions of it); align each line inside it.
        local full_norm = normText(doc:getTextFromXPointers(item.pos0, item.pos1) or "")
        built_text = ""
        cum = { [0] = 0 }
        if full_norm ~= "" then
            built_text = full_norm
            local search = 1
            for i = 1, n do
                local lt = line_texts[i]
                if lt ~= "" then
                    local p = built_text:find(lt, search, true)
                    if p then
                        cum[i] = p + #lt - 1
                        search = p + 1
                    else
                        cum[i] = cum[i - 1] + #lt
                    end
                else
                    cum[i] = cum[i - 1]
                end
            end
            if cum[n] < #built_text then
                cum[n] = #built_text
            end
        else
            for i = 1, n do
                local lt = line_texts[i]
                if i > 1 and lt ~= "" then
                    if built_text:sub(-1) == "-" and lt:match("^%w") then
                        -- hyphenation split across lines: join without the dash
                        built_text = built_text:sub(1, -2) .. lt
                    else
                        built_text = built_text .. " " .. lt
                    end
                else
                    built_text = built_text .. lt
                end
                cum[i] = #built_text
            end
        end

        self._line_cache = {
            key = item.pos0,
            screen_w = cur_w,
            screen_h = cur_h,
            page = cur_page,
            built_text = built_text,
            cum = cum,
            sboxes = sboxes,
            n = n,
        }
    end

    -- ── Find the sentence in the built text ──────────────────────
    local sent_text = normText(item.text)
    if sent_text == "" then
        return false
    end
    local vis_start = built_text:find(sent_text, 1, true)
    if not vis_start then
        -- Sentence not on the visible part of the block (or an exotic
        -- rendering difference). No highlight this sentence; audio keeps
        -- going and the next sentence recovers.
        return false
    end
    local vis_end = vis_start + #sent_text - 1

    -- Find start and end lines
    local start_line = 1
    for i = 1, n do
        if cum[i] >= vis_start then
            start_line = i
            break
        end
    end
    local end_line = n
    for i = start_line, n do
        if cum[i] >= vis_end then
            end_line = i
            break
        end
    end

    local sb = sboxes[start_line]
    local eb = sboxes[end_line]
    if not sb or not eb then
        return false
    end

    -- ── Proportional x estimate within a line ───────────────────
    local function estimateX(box, line_idx, char_off)
        local total = cum[line_idx] - cum[line_idx - 1]
        if total <= 0 then
            return box.x
        end
        local x = box.x + math.floor((char_off / total) * box.w)
        return math.max(box.x, math.min(box.x + box.w - 1, x))
    end

    -- ── Query CRe for the text selected between two points ──────
    local function querySelection(sx, sy, ex, ey)
        local ok, r = pcall(doc.getTextFromPositions, doc,
            { x = sx, y = sy }, { x = ex, y = ey }, true)
        if not ok or not r or not r.text then
            return ""
        end
        return normText(r.text)
    end

    local start_y = sb.y + math.floor(sb.h / 2)
    local end_y = eb.y + math.floor(eb.h / 2)

    local sl_off = vis_start - cum[start_line - 1]
    local el_off = vis_end - cum[end_line - 1]
    local start_x = estimateX(sb, start_line, math.max(0, sl_off - 1))
    local end_x = estimateX(eb, end_line, el_off)

    local want_text = built_text:sub(vis_start, vis_end)
    if want_text == "" then
        want_text = sent_text
    end
    local want_len = #want_text

    -- ── Binary-search refinement for end_x (CRe snaps to words) ──
    local function refineEndX(cur_sx, cur_sy, cur_ey)
        local function scoreOf(text)
            local len = #text
            if text == want_text then
                return 0
            end
            if len >= want_len and len <= want_len + 6 then
                return 1 + (len - want_len)
            end
            if len < want_len then
                return 100 + (want_len - len)
            end
            return 200 + (len - want_len)
        end

        local best_x = end_x
        local best_score = scoreOf(querySelection(cur_sx, cur_sy, end_x, cur_ey))
        if best_score == 0 then
            return end_x
        end

        local lo, hi = eb.x, eb.x + eb.w - 1
        for _ = 1, 8 do
            if hi - lo < 2 then
                break
            end
            local mid = math.floor((lo + hi) / 2)
            local mid_text = querySelection(cur_sx, cur_sy, mid, cur_ey)
            local score = scoreOf(mid_text)
            if score < best_score then
                best_score = score
                best_x = mid
            end
            if mid_text == want_text then
                return mid
            elseif #mid_text > want_len then
                hi = mid
            else
                lo = mid
            end
        end
        return best_x
    end

    end_x = refineEndX(start_x, start_y, end_y)

    -- ── Always refine start_x (CRe can drop the first word) ──────
    do
        local want_start = want_text:sub(1, math.min(20, #want_text))
        local got = querySelection(start_x, start_y, end_x, end_y)
        local got_start = got:sub(1, math.min(20, #got))
        if got_start ~= want_start then
            local lo = sb.x
            local hi = math.min(sb.x + sb.w - 1, start_x + math.floor(sb.w * 0.3))
            local best_x = start_x
            for _ = 1, 8 do
                if hi - lo < 2 then
                    break
                end
                local mid = math.floor((lo + hi) / 2)
                local mid_text = querySelection(mid, start_y, end_x, end_y)
                local mid_start = mid_text:sub(1, math.min(20, #mid_text))
                if mid_start == want_start then
                    best_x = mid
                    hi = mid
                else
                    lo = mid
                end
            end
            start_x = best_x
            end_x = refineEndX(start_x, start_y, end_y)
        end
    end

    -- ── Build final boxes ────────────────────────────────────────
    local boxes
    local final_ok, final_res = pcall(doc.getTextFromPositions, doc,
        { x = start_x, y = start_y }, { x = end_x, y = end_y }, true)
    if final_ok and final_res and final_res.pos0 and final_res.pos1 then
        local cre_text = final_res.text and normText(final_res.text) or ""
        local len_ok = #cre_text >= want_len - 2 and #cre_text <= want_len + 6
        if len_ok then
            local ok_cb, cre_boxes = pcall(doc.getScreenBoxesFromPositions, doc,
                final_res.pos0, final_res.pos1, true)
            if ok_cb and cre_boxes and #cre_boxes > 0 then
                boxes = {}
                for _, cb in ipairs(cre_boxes) do
                    if cb.w > 0 and cb.h > 0 then
                        table.insert(boxes, { x = cb.x, y = cb.y, w = cb.w, h = cb.h })
                    end
                end
                if #boxes == 0 then
                    boxes = nil
                end
            end
        end
    end
    if not boxes then
        -- Fallback: line-map boxes with the estimated pixel coords
        boxes = {}
        for i = start_line, end_line do
            local box = sboxes[i]
            local bx, bw = box.x, box.w
            if i == start_line and i == end_line then
                bx = start_x
                bw = end_x - start_x
            elseif i == start_line then
                bw = (box.x + box.w) - start_x
                bx = start_x
            elseif i == end_line then
                bw = end_x - box.x
            end
            if bw > 0 and box.h > 0 then
                table.insert(boxes, { x = bx, y = box.y, w = bw, h = box.h })
            end
        end
    end

    if #boxes > 0 then
        self._pending_boxes = boxes
        self:_captureViewForBoxes()
        self:_ensureViewModule()
        self:_refreshHighlight(boxes, cur_page)
        return true
    end
    return false
end

--- Register a view module so our paintTo runs after page content is drawn.
function SentenceHighlight:_ensureViewModule()
    if self._view_module_registered then
        return
    end
    if not self.ui or not self.ui.view then
        return
    end
    local hm = self
    local module = { paintTo = function(_, bb, _x, _y) hm:_paintOverlay(bb) end }
    self.ui.view:registerViewModule("tts_sentence_highlight", module)
    self._view_module_registered = true
end

--- Paint highlight rectangles on the framebuffer (all styles).
function SentenceHighlight:_paintOverlay(bb)
    local boxes = self._pending_boxes
    if not boxes or #boxes == 0 then
        return
    end
    if not self:_boxesMatchCurrentView() then
        self._pending_boxes = nil
        self._pending_view_page = nil
        self._pending_view_pos = nil
        return
    end
    if not bb then
        return
    end
    local line_w = Screen:scaleBySize(2)
    local sw, sh = Screen:getWidth(), Screen:getHeight()

    for _, box in ipairs(boxes) do
        local bx = math.max(0, box.x)
        local by = math.max(0, box.y)
        local bw = math.min(box.w - (bx - box.x), sw - bx)
        local bh = math.min(box.h - (by - box.y), sh - by)
        if bw > 0 and bh > 0 then
            if self.style == self.STYLES.INVERT then
                pcall(function() bb:invertRect(bx, by, bw, bh) end)
            elseif self.style == self.STYLES.UNDERLINE then
                bb:paintRect(bx, by + bh - line_w, bw, line_w, Blitbuffer.COLOR_BLACK)
            elseif self.style == self.STYLES.BACKGROUND then
                bb:darkenRect(bx, by, bw, bh, 0.2)
            elseif self.style == self.STYLES.BOX then
                bb:paintRect(bx, by, bw, line_w, Blitbuffer.COLOR_BLACK)
                bb:paintRect(bx, by + bh - line_w, bw, line_w, Blitbuffer.COLOR_BLACK)
                bb:paintRect(bx, by, line_w, bh, Blitbuffer.COLOR_BLACK)
                bb:paintRect(bx + bw - line_w, by, line_w, bh, Blitbuffer.COLOR_BLACK)
            end
        end
    end
end

--- Clear all highlights (refresh only the strip where they were).
function SentenceHighlight:clearHighlights()
    local had_boxes = self._pending_boxes ~= nil
    self._pending_boxes = nil
    self._pending_view_page = nil
    self._pending_view_pos = nil
    self._line_cache = nil
    if had_boxes then
        self:_refreshHighlight(nil, self._last_boxes_page)
    end
    self._last_boxes = nil
    self._last_boxes_page = nil
end

return SentenceHighlight