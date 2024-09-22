local M = {}
local Job = require("plenary.job")

local function get_api_key(name)
	print(os.getenv(name))
	return os.getenv(name)
end

function M.get_lines_until_cursor()
	local current_buffer = vim.api.nvim_get_current_buf()
	local current_window = vim.api.nvim_get_current_win()
	local cursor_position = vim.api.nvim_win_get_cursor(current_window)
	local row = cursor_position[1]

	local lines = vim.api.nvim_buf_get_lines(current_buffer, 0, row, true)

	return table.concat(lines, "\n")
end

function M.get_visual_selection()
	local mode = vim.fn.mode()
	if mode ~= "v" and mode ~= "V" and mode ~= "\22" then
		return nil
	end

	local _, start_row, start_col, _ = unpack(vim.fn.getpos("'<"))
	local _, end_row, end_col, _ = unpack(vim.fn.getpos("'>"))
	start_row = start_row - 1 -- Convert to 0-indexed
	end_row = end_row - 1
	start_col = start_col - 1

	local lines = {}
	if mode == "V" then
		lines = vim.api.nvim_buf_get_lines(0, start_row, end_row + 1, false)
		end_col = -1 -- Select whole lines
	elseif mode == "v" then
		lines = vim.api.nvim_buf_get_text(0, start_row, start_col, end_row, end_col, {})
	elseif mode == "\22" then -- Visual block mode
		for i = start_row, end_row do
			local line =
				vim.api.nvim_buf_get_text(0, i, math.min(start_col, end_col), i, math.max(start_col, end_col), {})[1]
			table.insert(lines, line)
		end
	end

	return {
		lines = lines,
		start_row = start_row,
		start_col = start_col,
		end_row = end_row,
		end_col = end_col,
		mode = mode,
	}
end

function M.make_anthropic_spec_curl_args(opts, prompt, system_prompt)
	local url = opts.url
	local api_key = opts.api_key_name and get_api_key(opts.api_key_name)
	local data = {
		url = "https://api.anthropic.com/v1/messages",
		system = system_prompt,
		messages = { { role = "user", content = prompt } },
		model = opts.model,
		stream = true,
		max_tokens = 4096,
	}
	local args = { "-N", "-X", "POST", "-H", "Content-Type: application/json", "-d", vim.json.encode(data) }
	if api_key then
		table.insert(args, "-H")
		table.insert(args, "x-api-key: " .. api_key)
		table.insert(args, "-H")
		table.insert(args, "anthropic-version: 2023-06-01")
	end
	table.insert(args, url)
	print("curl args: " .. vim.inspect(args))
	return args
end

function M.make_openai_spec_curl_args(opts, prompt, system_prompt)
	local url = opts.url
	local api_key = opts.api_key_name and get_api_key(opts.api_key_name)
	local data = {
		messages = { { role = "system", content = system_prompt }, { role = "user", content = prompt } },
		model = opts.model,
		temperature = 0.7,
		stream = true,
	}
	local args = { "-N", "-X", "POST", "-H", "Content-Type: application/json", "-d", vim.json.encode(data) }
	if api_key then
		table.insert(args, "-H")
		table.insert(args, "Authorization: Bearer " .. api_key)
	end
	table.insert(args, url)
	return args
end

function M.write_string_at_cursor(str)
	vim.schedule(function()
		local current_window = vim.api.nvim_get_current_win()
		local cursor_position = vim.api.nvim_win_get_cursor(current_window)
		local row, col = cursor_position[1], cursor_position[2]

		local lines = vim.split(str, "\n")

		vim.cmd("undojoin")
		vim.api.nvim_put(lines, "c", true, true)

		local num_lines = #lines
		local last_line_length = #lines[num_lines]
		vim.api.nvim_win_set_cursor(current_window, { row + num_lines - 1, col + last_line_length })
	end)
end

local function get_prompt(opts)
	local replace = opts.replace
	local visual_lines = M.get_visual_selection()
	local prompt = ""

	if visual_lines then
		prompt = table.concat(visual_lines, "\n")
		if replace then
			vim.api.nvim_command("normal! d")
			vim.api.nvim_command("normal! k")
		else
			vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", false, true, true), "nx", false)
		end
	else
		prompt = M.get_lines_until_cursor()
	end

	return prompt
end

function M.handle_anthropic_spec_data(data_stream, event_state)
	if event_state == "content_block_delta" then
		local json = vim.json.decode(data_stream)
		if json.delta and json.delta.text then
			M.write_string_at_cursor(json.delta.text)
		end
	end
end

function M.handle_openai_spec_data(data_stream)
	if data_stream:match('"delta":') then
		local json = vim.json.decode(data_stream)
		if json.choices and json.choices[1] and json.choices[1].delta then
			local content = json.choices[1].delta.content
			if content then
				M.write_string_at_cursor(content)
			end
		end
	end
end

local group = vim.api.nvim_create_augroup("DING_LLM_AutoGroup", { clear = true })
local active_job = nil

function M.invoke_llm_and_stream_into_editor(opts, make_curl_args_fn, handle_data_fn)
	vim.api.nvim_clear_autocmds({ group = group })
	local selection = M.get_visual_selection()
	local prompt = ""
	local start_row, end_row, start_col, end_col

	print("LLM inference in progress...")

	if selection then
		prompt = table.concat(selection.lines, "\n")
		start_row, end_row = selection.start_row, selection.end_row
		start_col, end_col = selection.start_col, selection.end_col
		if opts.replace then
			if selection.mode == "V" then
				vim.api.nvim_buf_set_lines(0, start_row, end_row + 1, false, {})
			else
				vim.api.nvim_buf_set_text(0, start_row, start_col, end_row, end_col, {})
			end
		else
			vim.api.nvim_win_set_cursor(0, { end_row + 1, 0 })
		end
		vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", false, true, true), "nx", false)
	else
		prompt = M.get_lines_until_cursor()
		local cursor = vim.api.nvim_win_get_cursor(0)
		start_row, start_col = cursor[1] - 1, cursor[2]
		if opts.replace then
			vim.api.nvim_buf_set_lines(0, start_row, start_row + 1, false, {})
		end
	end

	local system_prompt = opts.system_prompt
		or "You are a tsundere uwu anime. Yell at me for not setting my configuration for my llm plugin correctly"
	local args = make_curl_args_fn(opts, prompt, system_prompt)
	print("Curl args: " .. vim.inspect(args))
	local curr_event_state = nil

	local function parse_and_call(line)
		print("Received line: " .. line)
		local event = line:match("^event: (.+)$")
		if event then
			curr_event_state = event
			return
		end
		local data_match = line:match("^data: (.+)$")
		if data_match then
			handle_data_fn(data_match, curr_event_state)
		end
	end

	if active_job then
		active_job:shutdown()
		active_job = nil
	end

	active_job = Job:new({
		command = "curl",
		args = args,
		on_stdout = function(_, out)
			parse_and_call(out)
		end,
		on_stderr = function(_, err)
			print("Curl error: " .. err)
		end,

		on_exit = function(_, code)
			print("Curl exited with code: " .. code)
			active_job = nil
		end,
	})

	active_job:start()

	vim.api.nvim_create_autocmd("User", {
		group = group,
		pattern = "DING_LLM_Escape",
		callback = function()
			if active_job then
				active_job:shutdown()
				print("LLM streaming cancelled")
				active_job = nil
			end
		end,
	})

	vim.api.nvim_set_keymap("n", "<Esc>", ":doautocmd User DING_LLM_Escape<CR>", { noremap = true, silent = true })
	return active_job
end

return M
