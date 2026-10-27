--[[--
Text Parser Module (ported from stradichenko/audiobook.koplugin, trimmed).

Splits text into sentences at natural boundaries. Long sentences are
further split at clause boundaries for TTS safety (chunks of 100-300
chars are the efficient window for piper).

@module textparser
--]]

local TextParser = {
    SENTENCE_ENDINGS = "[%.%?!]",
    WORD_SEPARATORS = "[%s%p]",
}

-- Long-sentence splitting thresholds (from audiobook benchmarks):
-- chunks below 80 chars waste synthesis time on per-request overhead.
local MAX_CHUNK_CHARS = 300
local MIN_CHUNK_CHARS = 80

function TextParser:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    return o
end

--[[--
Normalize text: control chars, line-wrap hyphenation, whitespace.
--]]
function TextParser:normalizeText(text)
    -- Normalize line endings to \n
    text = text:gsub("\r\n", "\n")
    text = text:gsub("\r", "\n")

    -- Strip C0 control chars except \t and \n (PocketBook extractors emit them)
    text = text:gsub("[%z\1-\8\11\12\14-\31]", "")

    -- PDF-derived EPUBs wrap each visual line with a newline; keep real
    -- paragraph breaks (blank lines) via a sentinel, join the rest.
    local PARA_SENTINEL = "\1\2\3"
    text = text:gsub("\n[ \t]*\n+", PARA_SENTINEL)
    -- Join hyphen-split words ("re-\nduce" -> "reduce")
    text = text:gsub("([^%s%p])%-\n([^%s%p])", "%1%2")
    text = text:gsub("\n", " ")
    text = text:gsub(PARA_SENTINEL, "\n")

    -- Collapse runs of spaces/tabs (not newlines)
    text = text:gsub("[ \t]+", " ")
    text = text:match("^%s*(.-)%s*$")

    -- Defensive guard: extractor emitting one word per line -> join
    local line_count, short_line_count = 0, 0
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
        if line ~= "" then
            line_count = line_count + 1
            if #line <= 2 then
                short_line_count = short_line_count + 1
            end
        end
    end
    if line_count > 5 and short_line_count / line_count > 0.5 then
        text = text:gsub("\n", " ")
        text = text:gsub("[ \t]+", " ")
    end

    return text
end

--[[--
Parse text into sentences.
@return table Array of sentence objects { index, text, start_pos, end_pos, end_type }
--]]
function TextParser:parse(text)
    local sentences = {}
    if not text or text == "" then
        return { sentences = sentences }
    end

    text = self:normalizeText(text)
    local sentence_index = 1

    local function addSentence(s, end_type)
        s = s:match("^%s*(.-)%s*$")
        if s and s ~= "" then
            table.insert(sentences, {
                index = sentence_index,
                text = s,
                start_pos = 0,
                end_pos = 0,
                end_type = end_type or "sentence",
            })
            sentence_index = sentence_index + 1
        end
    end

    -- Step 1: split on newlines (real paragraph breaks)
    for line in (text .. "\n"):gmatch("([^\n]+)\n") do
        line = line:match("^%s*(.-)%s*$")
        if line and line ~= "" then
            -- Step 2: split each line on sentence-ending punctuation
            local ell = "\226\128\166" -- …
            local cjk_endings = {
                ell,
                "\227\128\130", -- 。 U+3002
                "\239\188\129", -- ！ U+FF01
                "\239\188\159", -- ？ U+FF1F
            }
            local cjk_closers =
                "[\226\128\157\227\128\139\227\128\141\227\128\143\239\188\137\227\128\145\"]*"
            local pos = 1
            local segments_in_line = {}
            while pos <= #line do
                local best_s, best_e
                local function consider(s, e)
                    if s and (not best_s or s < best_s) then
                        best_s, best_e = s, e
                    end
                end
                consider(line:find("[%.%?!]+%s", pos))
                consider(line:find("[%.%?!]+$", pos))
                for _, term in ipairs(cjk_endings) do
                    consider(line:find(term .. cjk_closers, pos))
                end
                local pstart, pend = best_s, best_e
                if pstart then
                    local seg_end = pend
                    if line:sub(pend, pend):match("%s") then
                        seg_end = pend - 1
                    end
                    table.insert(segments_in_line, line:sub(pos, seg_end))
                    pos = seg_end + 1
                    while pos <= #line and line:sub(pos, pos):match("%s") do
                        pos = pos + 1
                    end
                else
                    table.insert(segments_in_line, line:sub(pos))
                    break
                end
            end
            for i, seg in ipairs(segments_in_line) do
                local etype = (i == #segments_in_line) and "paragraph" or "sentence"
                addSentence(seg, etype)
            end
        end
    end

    -- Step 3: split sentences over MAX_CHUNK_CHARS at clause boundaries
    local expanded = {}
    local new_index = 1
    for _, sentence in ipairs(sentences) do
        if #sentence.text > MAX_CHUNK_CHARS then
            local chunks = self:splitLongSentence(sentence.text, MAX_CHUNK_CHARS)
            for j, chunk in ipairs(chunks) do
                local etype = (j == #chunks) and sentence.end_type or "sentence"
                table.insert(expanded, {
                    index = new_index,
                    text = chunk,
                    start_pos = 0,
                    end_pos = 0,
                    end_type = etype,
                })
                new_index = new_index + 1
            end
        else
            sentence.index = new_index
            table.insert(expanded, sentence)
            new_index = new_index + 1
        end
    end
    sentences = expanded

    -- Recalculate positions relative to the normalized text
    local search_from = 1
    for _, sentence in ipairs(sentences) do
        local found = text:find(sentence.text, search_from, true)
        if found then
            sentence.start_pos = found
            sentence.end_pos = found + #sentence.text - 1
            search_from = sentence.end_pos + 1
        end
    end

    return { sentences = sentences }
end

--[[--
Split a long sentence into clause-aware chunks.
--]]
function TextParser:splitLongSentence(text, max_chars)
    max_chars = max_chars or MAX_CHUNK_CHARS
    if #text <= max_chars then
        return { text }
    end
    local chunks = self:_splitAtClauses(text)
    chunks = self:_mergeSmallChunks(chunks, MIN_CHUNK_CHARS, max_chars)
    local final = {}
    for _, chunk in ipairs(chunks) do
        if #chunk > max_chars then
            local subs = self:_splitAtWordBoundary(chunk, max_chars)
            for _, sub in ipairs(subs) do
                table.insert(final, sub)
            end
        else
            table.insert(final, chunk)
        end
    end
    return final
end

function TextParser:_splitAtClauses(text)
    local conjunctions = {
        "and", "but", "or", "nor", "for", "yet", "so",
        "which", "who", "that", "where", "when", "while",
        "although", "because", "since", "unless", "if",
        "after", "before",
    }
    local cjk_clauses = {
        "\239\188\140", -- ， U+FF0C
        "\227\128\129", -- 、 U+3001
        "\239\188\155", -- ； U+FF1B
        "\239\188\154", -- ： U+FF1A
    }

    local chunks = {}
    local current = ""
    local pos = 1

    while pos <= #text do
        local ch = text:sub(pos, pos)
        local three = text:sub(pos, pos + 2)
        local is_cjk_clause = false
        for _, mark in ipairs(cjk_clauses) do
            if three == mark then
                is_cjk_clause = true
                break
            end
        end
        if is_cjk_clause then
            current = current .. three
            table.insert(chunks, current)
            current = ""
            pos = pos + 3
        elseif (ch == ";" or ch == ":") and text:sub(pos + 1, pos + 1) == " " then
            current = current .. ch
            table.insert(chunks, current)
            current = ""
            pos = pos + 2
        elseif text:sub(pos, pos + 2) == " - " then
            current = current .. " -"
            table.insert(chunks, current)
            current = ""
            pos = pos + 3
        elseif ch == "," and text:sub(pos + 1, pos + 1) == " " then
            local rest = text:sub(pos + 2)
            local found_conj = false
            for _, conj in ipairs(conjunctions) do
                if rest:find("^" .. conj .. "%s") or rest:find("^" .. conj .. "$") then
                    current = current .. ","
                    table.insert(chunks, current)
                    current = ""
                    pos = pos + 2
                    found_conj = true
                    break
                end
            end
            if not found_conj then
                current = current .. ch
                pos = pos + 1
            end
        else
            current = current .. ch
            pos = pos + 1
        end
    end

    if current ~= "" then
        table.insert(chunks, current)
    end

    local result = {}
    for _, chunk in ipairs(chunks) do
        chunk = chunk:match("^%s*(.-)%s*$")
        if chunk and chunk ~= "" then
            table.insert(result, chunk)
        end
    end
    return result
end

function TextParser:_mergeSmallChunks(chunks, min_chars, max_chars)
    if #chunks <= 1 then
        return chunks
    end
    local merged = {}
    for _, chunk in ipairs(chunks) do
        if #chunk < min_chars and #merged > 0
            and (not max_chars or #merged[#merged] + 1 + #chunk <= max_chars) then
            merged[#merged] = merged[#merged] .. " " .. chunk
        else
            table.insert(merged, chunk)
        end
    end
    if #merged > 1 and #merged[1] < min_chars
        and (not max_chars or #merged[1] + 1 + #merged[2] <= max_chars) then
        merged[2] = merged[1] .. " " .. merged[2]
        table.remove(merged, 1)
    end
    return merged
end

function TextParser:_splitAtWordBoundary(text, max_chars)
    local chunks = {}
    local remaining = text

    while #remaining > max_chars do
        local split_pos = max_chars
        while split_pos > 0 and remaining:sub(split_pos, split_pos) ~= " " do
            split_pos = split_pos - 1
        end
        local hard_cut = false
        if split_pos == 0 then
            hard_cut = true
            split_pos = max_chars
            while split_pos > 1 do
                local b = remaining:byte(split_pos)
                if b and b >= 0x80 and b < 0xC0 then
                    split_pos = split_pos - 1
                else
                    break
                end
            end
        end
        table.insert(chunks, remaining:sub(1, split_pos - 1))
        if hard_cut then
            remaining = remaining:sub(split_pos)
        else
            remaining = remaining:sub(split_pos + 1)
        end
    end

    if #remaining > 0 then
        if #remaining < MIN_CHUNK_CHARS and #chunks > 0 then
            chunks[#chunks] = chunks[#chunks] .. " " .. remaining
        else
            table.insert(chunks, remaining)
        end
    end
    return chunks
end

return TextParser