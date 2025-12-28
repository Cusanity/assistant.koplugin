local logger = require("logger")
local InputDialog = require("ui/widget/inputdialog")
local ChatGPTViewer = require("assistant_viewer")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local TextBoxWidget = require("ui/widget/textboxwidget")
local _ = require("assistant_gettext")
local T = require("ffi/util").template
local Event = require("ui/event")
local koutil = require("util")
local assistant_utils = require("assistant_utils")
local dict_prompts = require("assistant_prompts").assistant_prompts.dict

-- Expand context sentences to include surrounding sentences for pronouns and related narrative
-- This captures "he", "she", "they" and nearby actions that provide important context
-- OPTIMIZED: Now accepts pre-tokenized sentences and indices to avoid re-tokenization
-- all_sentences: array of all sentences in the text (pre-tokenized)
-- selected_indices: array of indices of selected sentences in all_sentences
-- context_window_before/after: number of surrounding sentences to include
local function expandContextWithSurroundings(all_sentences, selected_indices, context_window_before, context_window_after)
    if not selected_indices or #selected_indices == 0 then
        return {}
    end

    context_window_before = context_window_before or 1  -- Include 1 sentence before
    context_window_after = context_window_after or 1    -- Include 1 sentence after

    -- Expand the indices to include surrounding context
    local expanded_indices = {}
    local expanded_set = {}

    for _, idx in ipairs(selected_indices) do
        -- Include context_window_before sentences before and context_window_after after
        for neighbor_idx = math.max(1, idx - context_window_before), math.min(#all_sentences, idx + context_window_after) do
            if not expanded_set[neighbor_idx] then
                table.insert(expanded_indices, neighbor_idx)
                expanded_set[neighbor_idx] = true
            end
        end
    end

    -- Sort by document order
    table.sort(expanded_indices)

    -- Build the expanded context from the expanded indices
    local expanded_sentences = {}
    for _, idx in ipairs(expanded_indices) do
        table.insert(expanded_sentences, all_sentences[idx])
    end

    return expanded_sentences
end

local function showDictionaryDialog(assistant, highlightedText, message_history, prompt_type)
    local CONFIGURATION = assistant.CONFIGURATION
    local Querier = assistant.querier
    local ui = assistant.ui

    -- Check if Querier is initialized
    local ok, err = Querier:load_model(assistant:getModelProvider())
    if not ok then
        UIManager:show(InfoMessage:new{ icon = "notice-warning", text = err })
        return
    end

    -- Handle case where no text is highlighted (gesture-triggered)
    local input_dialog
    if not highlightedText or highlightedText == "" then
        -- Show a simple input dialog to ask for a word to look up
        input_dialog = InputDialog:new{
            title = _("AI Dictionary"),
            input_hint = _("Enter a word to look up..."),
            input_type = "text",
            buttons = {
                {
                    {
                        text = _("Cancel"),
                        callback = function()
                            UIManager:close(input_dialog)
                        end,
                    },
                    {
                        text = _("Look Up"),
                        is_enter_default = true,
                        callback = function()
                            local word = input_dialog:getInputText()
                            UIManager:close(input_dialog)
                            if word and word ~= "" then
                                -- Recursively call with the entered word
                                showDictionaryDialog(assistant, word, message_history)
                            end
                        end,
                    },
                }
            }
        }
        UIManager:show(input_dialog)
        input_dialog:onShowKeyboard()
        return
    end

    local message_history = message_history or {}

    -- Set up system prompt based on prompt type
    if #message_history == 0 then
        local system_prompt
        if prompt_type == "term_xray" then
            local term_xray_prompts = require("assistant_prompts").custom_prompts.term_xray
            system_prompt = term_xray_prompts.system_prompt
        else
            system_prompt = dict_prompts.system_prompt
        end

        table.insert(message_history, {
            role = "system",
            content = system_prompt,
        })
    end

    -- Get context for the selected word
    local prev_context, next_context = "", ""
    local context_text = ""
    local context_sentence_count = 0
    local dict_language = assistant.settings:readSetting("response_language") or assistant.ui_language

    if prompt_type == "term_xray" then
        -- FAST MODE: Simple text search for sentences containing the term
        -- No LexRank - just find matching sentences with surrounding context
        
        -- Get book text up to current reading position
        local book_text = assistant_utils.extractBookTextForAnalysis(CONFIGURATION, ui)

        if book_text and #book_text > 100 then
            -- Simple sentence splitting (supports English and Chinese punctuation)
            local all_sentences = {}
            local current_sentence = ""

            -- Use utf8 iteration to properly handle multi-byte Chinese characters
            for char in book_text:gmatch("([%z\1-\127\194-\244][\128-\191]*)") do
                current_sentence = current_sentence .. char

                -- English: .!?; | Chinese: 。！？；
                if char:match("[.!?;]") or char == "。" or char == "！" or char == "？" or char == "；" then
                    local trimmed = current_sentence:gsub("^%s*(.-)%s*$", "%1")
                    if #trimmed > 10 then
                        table.insert(all_sentences, trimmed)
                    end
                    current_sentence = ""
                end
            end

            -- Add remaining text as sentence if long enough
            local trimmed = current_sentence:gsub("^%s*(.-)%s*$", "%1")
            if #trimmed > 10 then
                table.insert(all_sentences, trimmed)
            end

            -- Find ALL sentences containing the term (case-insensitive)
            local matching_indices = {}
            local term_lower = highlightedText:lower()

            for i, sentence in ipairs(all_sentences) do
                if sentence:lower():find(term_lower, 1, true) then
                    table.insert(matching_indices, i)
                end
            end

            -- Expand context around matching sentences
            local context_before = koutil.tableGetValue(CONFIGURATION, "features", "term_xray_context_sentences_before") or 2
            local context_after = koutil.tableGetValue(CONFIGURATION, "features", "term_xray_context_sentences_after") or 2
            local context_sentences = expandContextWithSurroundings(
                all_sentences,
                matching_indices,
                context_before,
                context_after
            )

            -- Concatenate context sentences
            context_text = table.concat(context_sentences, " ")

            -- Truncate to max characters limit
            local max_characters = koutil.tableGetValue(CONFIGURATION, "features", "term_xray_max_characters") or 50000
            if #context_text > max_characters then
                context_text = context_text:sub(1, max_characters)
            end

            context_sentence_count = #context_sentences
        else
            -- Fallback to standard context if book text is too short
            context_text = prev_context .. highlightedText .. next_context
        end
    else
        -- Standard dictionary context extraction
        if ui.highlight and ui.highlight.getSelectedWordContext then
            -- Helper function to count words in a string.
            local function countWords(str)
                if not str or str == "" then return 0 end
                local _, count = string.gsub(str, "%S+", "")
                return count
            end

            local use_fallback_context = true
            -- Try to get the full sentence containing the word. If `getSelectedSentence()` doesn't exist,
            -- the code will gracefully use the fallback method.
            if ui.highlight.getSelectedSentence then
                local success, sentence = pcall(function() return ui.highlight:getSelectedSentence() end)
                if success and sentence then
                    -- Find the selected word in the sentence to split it.
                    local word_start, word_end = string.find(sentence, highlightedText, 1, true)
                    if word_start then
                        local prev_part = string.sub(sentence, 1, word_start - 1)
                        local next_part = string.sub(sentence, word_end + 1)

                        -- Check if the sentence context is too short on both sides.
                        if countWords(prev_part) < 50 and countWords(next_part) < 50 then
                            -- The sentence is short, so we'll use the fallback to get more context.
                            use_fallback_context = true
                        else
                            -- The sentence provides enough context, so we'll use it.
                            prev_context = prev_part
                            next_context = next_part
                            use_fallback_context = false
                        end
                    end
                end
            end

            -- Use the fallback method (word count) if we couldn't get a good sentence context.
            if use_fallback_context then
                local success, prev, next = pcall(function()
                    return ui.highlight:getSelectedWordContext(50)
                end)
                if success then
                    prev_context = prev or ""
                    next_context = next or ""
                end
            end
        end
        context_text = prev_context .. highlightedText .. next_context
    end

    -- Choose the appropriate prompt and context based on prompt type
    local user_prompt, context_content, title, loading_message
    if prompt_type == "term_xray" then
        local term_xray_prompts = require("assistant_prompts").custom_prompts.term_xray
        user_prompt = term_xray_prompts.user_prompt
        context_content = context_text

        -- Get book information for term_xray
        local prop = ui.document:getProps()
        local book_title = prop.title or "Unknown Title"
        local book_author = prop.authors or "Unknown Author"
        title = _("Term X-Ray")
        loading_message = _("Loading Term X-Ray ...")
        local context_message = {
            role = "user",
            content = string.gsub(user_prompt, "{(%w+)}", {
                    language = dict_language,
                    context = context_content,
                    context_sentence_count = context_sentence_count,
                    highlight = highlightedText,
                    title = book_title,
                    author = book_author,
                    user_input = ""
            })
        }
        table.insert(message_history, context_message)
    else
        user_prompt = dict_prompts.user_prompt
        context_content = prev_context .. highlightedText .. next_context
        title = _("Dictionary")
        loading_message = _("Loading AI Dictionary ...")
        local context_message = {
            role = "user",
            content = string.gsub(user_prompt, "{(%w+)}", {
                    language = dict_language,
                    context = context_content,
                    word = highlightedText
            })
        }
        table.insert(message_history, context_message)
    end

    -- Query the AI with the message history
    local ret, err = Querier:query(message_history, loading_message)
    if err ~= nil then
        assistant.querier:showError(err)
        return
    end

    local function createResultText(highlightedText, answer, is_term_xray)
        local result_text
        local render_markdown = koutil.tableGetValue(CONFIGURATION, "features", "render_markdown") or true
        local normalized_answer = assistant_utils.normalizeMarkdownHeadings(answer, 2, 6) or answer
        
        -- For Term X-Ray, just return the AI response directly (it has its own header)
        if is_term_xray then
            return normalized_answer
        end
        
        -- For Dictionary, show the word in context header
        local prev_context_limited = string.sub(prev_context, -100)
        local next_context_limited = string.sub(next_context, 1, 100)
        if render_markdown then
            -- in markdown mode, outputs markdown formatted highlighted text
            result_text = T("... %1 **%2** %3 ...\n\n%4", prev_context_limited, highlightedText, next_context_limited, normalized_answer)
        else
            -- in plain text mode, use widget controlled characters.
            result_text = T("%1... %2%3%4 ...\n\n%5", TextBoxWidget.PTF_HEADER, prev_context_limited, 
                TextBoxWidget.PTF_BOLD_START, highlightedText, TextBoxWidget.PTF_BOLD_END,  next_context_limited, normalized_answer)
        end
        return result_text
    end

    local result = createResultText(highlightedText, ret, prompt_type == "term_xray")
    local chatgpt_viewer

    local function handleAddToNote()
        if ui.highlight and ui.highlight.saveHighlight then
            local success, index = pcall(function()
                return ui.highlight:saveHighlight(true)
            end)
            if success and index then
                local a = ui.annotation.annotations[index]
                a.note = result
                ui:handleEvent(Event:new("AnnotationsModified",
                                    { a, nb_highlights_added = -1, nb_notes_added = 1 }))
            end
        end

        UIManager:close(chatgpt_viewer)
        if ui.highlight and ui.highlight.onClose then
            ui.highlight:onClose()
        end
    end

    chatgpt_viewer = ChatGPTViewer:new {
        assistant = assistant,
        ui = ui,
        title = title,
        text = result,
        onAddToNote = handleAddToNote,
        default_hold_callback = function ()
            chatgpt_viewer:HoldClose()
        end,
    }

    UIManager:show(chatgpt_viewer)
end

return showDictionaryDialog