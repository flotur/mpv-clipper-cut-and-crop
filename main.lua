-- NOTE TO FUTURE SELF:
-- To view debug logs when launching through Finder,
-- use the ` key in mpv instead of viewing ~/Library/Logs/mpv.log.

mp.msg.info("MPV-CUT LOADED")

local utils = require "mp.utils"

local function print(s)
	mp.msg.info(s)
	mp.osd_message(s)
end

local function table_to_str(o)
	if type(o) == 'table' then
		local s = ''
		for k,v in pairs(o) do
			if type(k) ~= 'number' then k = '"'..k..'"' end
			s = s .. '['..k..'] = ' .. table_to_str(v) .. '\n'
		end
		return s
	else
		return tostring(o)
	end
end

local result = mp.command_native({ name = "subprocess", args = {"ffmpeg"}, playback_only = false, capture_stdout = true, capture_stderr = true })
mp.msg.info("Your PATH: " .. tostring(os.getenv('PATH')))
if result.status ~= 1 then
	mp.osd_message("FFmpeg failed to run, please press ` for debug info", 5)
	mp.msg.error("FFmpeg failed to run:\n" .. table_to_str(result))
end

local function to_hms(seconds)
	local ms = math.floor((seconds - math.floor(seconds)) * 1000)
	local secs = math.floor(seconds)
	local mins = math.floor(secs / 60)
	secs = secs % 60
	local hours = math.floor(mins / 60)
	mins = mins % 60
	return string.format("%02d-%02d-%02d-%03d", hours, mins, secs, ms)
end

local function next_table_key(t, current)
	local keys = {}
	for k in pairs(t) do
		keys[#keys + 1] = k
	end
	table.sort(keys)
	for i = 1, #keys do
		if keys[i] == current then
			return keys[(i % #keys) + 1]
		end
	end
	return keys[1]
end

ACTIONS = {}

ACTIONS.COPY = function(d)
	local args = {
		"ffmpeg", "-nostdin", "-y", "-loglevel", "error",
		"-ss", d.start_time, "-t", d.duration, "-i", d.inpath,
		"-c", "copy", "-map", "0", "-dn", "-avoid_negative_ts", "make_zero",
		utils.join_path(d.indir, "COPY_" .. d.channel .. "_" .. d.infile_noext .. "_FROM_" .. d.start_time_hms .. "_TO_" .. d.end_time_hms .. d.ext)
	}
	mp.command_native_async({ name = "subprocess", args = args, playback_only = false }, function() print("Done") end)
end

ACTIONS.ENCODE = function(d)
	local args = {
		"ffmpeg", "-nostdin", "-y", "-loglevel", "error",
		"-ss", d.start_time, "-t", d.duration, "-i", d.inpath,
		"-pix_fmt", "yuv420p", "-crf", "16", "-preset", "superfast",
	}
	if d.crop_filter then
		table.insert(args, "-vf")
		table.insert(args, d.crop_filter)
	end
	table.insert(args, utils.join_path(d.indir, "ENCODE_" .. d.channel .. "_" .. d.infile_noext .. "_FROM_" .. d.start_time_hms .. "_TO_" .. d.end_time_hms .. d.ext))
	
	mp.command_native_async({ name = "subprocess", args = args, playback_only = false }, function() print("Done") end)
end

ACTIONS.CROP = function(d)
	if not d.crop_filter then
		print("ОШИБКА: Область кропа не выделена! Нажмите 'k' и выделите область мышью.")
		return
	end
	local args = {
		"ffmpeg", "-nostdin", "-y", "-loglevel", "error",
		"-ss", d.start_time, "-t", d.duration, "-i", d.inpath,
		"-pix_fmt", "yuv420p", "-crf", "16", "-preset", "superfast",
		"-vf", d.crop_filter,
		utils.join_path(d.indir, "CROP_" .. d.channel .. "_" .. d.infile_noext .. "_FROM_" .. d.start_time_hms .. "_TO_" .. d.end_time_hms .. d.ext)
	}
	mp.command_native_async({ name = "subprocess", args = args, playback_only = false }, function() print("Done") end)
end

ACTIONS.LIST = function(d)
	local inpath = mp.get_property("path")
	local outpath = inpath .. ".list"
	local file = io.open(outpath, "a")
	if not file then print("Error writing to cut list") return end
	local filesize = file:seek("end")
	local s = "\n" .. d.channel .. ":" .. d.start_time .. ":" .. d.end_time
	file:write(s)
	local delta = file:seek("end") - filesize
	io.close(file)
	print("Δ " .. delta)
end

ACTION = "COPY"
CHANNEL = 1
CHANNEL_NAMES = {}

KEY_CUT = "c"
KEY_CANCEL_CUT = "C"
KEY_CYCLE_ACTION = "a"
KEY_BOOKMARK_ADD = "i"
KEY_CHANNEL_INC = "="
KEY_CHANNEL_DEC = "-"
KEY_CROP_MODE = "k"

home_config = mp.command_native({"expand-path", "~/.config/mpv-cut/config.lua"})
if pcall(require, "config") then
    mp.msg.info("Loaded config file from script dir")
elseif pcall(dofile, home_config) then
    mp.msg.info("Loaded config file from " .. home_config)
else
    mp.msg.info("No config loaded")
end

for i, v in ipairs(CHANNEL_NAMES) do
    CHANNEL_NAMES[i] = string.gsub(v, ":", "-")
end

if not ACTIONS[ACTION] then ACTION = next_table_key(ACTIONS, nil) end

START_TIME = nil
local crop_mode = false
local crop_p1 = nil
local crop_p2 = nil
local CROP_FILTER = nil
local osc_was_enabled = true -- <-- НОВОЕ: сохраняем состояние OSC

local function get_current_channel_name()
	return CHANNEL_NAMES[CHANNEL] or tostring(CHANNEL)
end

local function get_data()
	local d = {}
	d.inpath = mp.get_property("path")
	d.indir = utils.split_path(d.inpath)
	d.infile = mp.get_property("filename")
	d.infile_noext = mp.get_property("filename/no-ext")
	d.ext = mp.get_property("filename"):match("^.+(%..+)$") or ".mp4"
	d.channel = get_current_channel_name()
	d.crop_filter = CROP_FILTER
	return d
end

local function get_times(start_time, end_time)
	local d = {}
	d.start_time = tostring(start_time)
	d.end_time = tostring(end_time)
	d.duration = tostring(end_time - start_time)
	d.start_time_hms = tostring(to_hms(start_time))
	d.end_time_hms = tostring(to_hms(end_time))
	d.duration_hms = tostring(to_hms(end_time - start_time))
	return d
end

text_overlay = mp.create_osd_overlay("ass-events")
text_overlay.hidden = true
text_overlay:update()

local function text_overlay_off()
	text_overlay:update()
	text_overlay.hidden = true
	text_overlay:update()
end

local function text_overlay_on()
	local channel = get_current_channel_name()
	text_overlay.data = string.format("%s in %s from %s", ACTION, channel, START_TIME)
	text_overlay.hidden = false
	text_overlay:update()
end

local function print_or_update_text_overlay(content)
	if START_TIME then text_overlay_on() else print(content) end
end

local function cycle_action()
	ACTION = next_table_key(ACTIONS, ACTION)
	print_or_update_text_overlay("ACTION: " .. ACTION)
end

local function cut(start_time, end_time)
	local d = get_data()
	local t = get_times(start_time, end_time)
	for k, v in pairs(t) do d[k] = v end
	mp.msg.info(ACTION)
	mp.msg.info(table_to_str(d))
	ACTIONS[ACTION](d)
end

local function put_time()
	local time = mp.get_property_number("time-pos")
	if not START_TIME then
		START_TIME = time
		text_overlay_on()
		return
	end
	text_overlay_off()
	if time > START_TIME then
		cut(START_TIME, time)
		START_TIME = nil
	else
		print("INVALID")
		START_TIME = nil
	end
end

local function cancel_cut()
	text_overlay_off()
	START_TIME = nil
	-- Если отменяем кроп, восстанавливаем OSC
	if crop_mode then
		crop_mode = false
		crop_p1 = nil
		crop_p2 = nil
		if osc_was_enabled then
			mp.set_property("osc", "yes")
		end
	end
	print("CANCELLED CUT")
end

local function get_bookmark_file_path()
	local d = get_data()
	local outfile = string.format("%s_%s.book", d.channel, d.infile)
	return utils.join_path(d.indir, outfile)
end

local function bookmarks_load()
	local inpath = get_bookmark_file_path()
	local file = io.open(inpath, "r")
	if not file then return end
	local arr = {}
	for line in file:lines() do
		if tonumber(line) then
			table.insert(arr, { time = tonumber(line), title = "chapter_" .. line })
		end
	end
	file:close()
	table.sort(arr, function(a, b) return a.time < b.time end)
	mp.set_property_native("chapter-list", arr)
end

local function bookmark_add()
	local d = get_data()
	local outpath = get_bookmark_file_path()
	local file = io.open(outpath, "a")
	if not file then print("Failed to open bookmark file for writing") return end
	local out_string = mp.get_property_number("time-pos") .. "\n"
	local filesize = file:seek("end")
	file:write(out_string)
	local delta = file:seek("end") - filesize
	io.close(file)
	bookmarks_load()
	print(string.format("Δ %s, %s", delta, d.channel))
end

local function channel_inc()
	CHANNEL = CHANNEL + 1
	bookmarks_load()
	print_or_update_text_overlay(get_current_channel_name())
end

local function channel_dec()
	if CHANNEL >= 2 then CHANNEL = CHANNEL - 1 end
	bookmarks_load()
	print_or_update_text_overlay(get_current_channel_name())
end

-- ==========================================
-- ЛОГИКА КАДРИРОВАНИЯ (CROP) МЫШЬЮ С АВТО-ОТКЛЮЧЕНИЕМ OSC
-- ==========================================

local function get_video_coords(mouse_x, mouse_y)
	local dims = mp.get_property_native("osd-dimensions")
	if not dims or not dims.w or not dims.h then
		mp.msg.warn("get_video_coords: osd-dimensions недоступен или неполный. Данные: " .. tostring(dims))
		return nil, nil
	end
	
	local v_w = dims["video-w"] or (dims.w - (dims.ml or 0) - (dims.mr or 0))
	local v_h = dims["video-h"] or (dims.h - (dims.mt or 0) - (dims.mb or 0))
	local v_x = dims["video-x"] or (dims.ml or 0)
	local v_y = dims["video-y"] or (dims.mt or 0)
	
	if v_w <= 0 or v_h <= 0 then
		mp.msg.warn("get_video_coords: Вычисленные размеры видео <= 0 (w="..v_w..", h="..v_h..")")
		return nil, nil
	end

	local video_params = mp.get_property_native("video-params")
	if not video_params or not video_params.w or not video_params.h then
		mp.msg.warn("get_video_coords: video-params недоступен или неполный. Данные: " .. tostring(video_params))
		return nil, nil
	end
	
	local p_w = video_params.w
	local p_h = video_params.h

	local mx = math.max(v_x, math.min(mouse_x, v_x + v_w))
	local my = math.max(v_y, math.min(mouse_y, v_y + v_h))

	local rel_x = (mx - v_x) / v_w
	local rel_y = (my - v_y) / v_h

	local vx = math.floor(rel_x * p_w)
	local vy = math.floor(rel_y * p_h)
	
	return vx, vy
end

local function handle_crop_click()
	if not crop_mode then return end
	
	local mouse = mp.get_property_native("mouse-pos")
	if not mouse or not mouse.x or not mouse.y then
		mp.msg.warn("handle_crop_click: mouse-pos недоступен. Данные: " .. tostring(mouse))
		mp.osd_message("Ошибка: не удалось получить координаты мыши. Попробуйте еще раз.", 3)
		return 
	end
	
	local vx, vy = get_video_coords(mouse.x, mouse.y)
	if not vx then 
		mp.osd_message("Ошибка: не удалось определить координаты видео. Подождите 1-2 сек после открытия файла и попробуйте снова.", 4)
		mp.msg.warn("Не удалось сопоставить координаты мыши ("..mouse.x..", "..mouse.y..") с видео.")
		return 
	end

	if not crop_p1 then
		crop_p1 = {x = vx, y = vy}
		mp.osd_message(string.format("КРОП: Верхний левый угол = %d, %d. Теперь нажмите Shift+ЛКМ для правого нижнего.", vx, vy), 5)
	else
		crop_p2 = {x = vx, y = vy}
		crop_mode = false
		
		-- Восстанавливаем OSC после завершения выбора
		if osc_was_enabled then
			mp.set_property("osc", "yes")
		end
		
		local min_x, max_x = math.min(crop_p1.x, crop_p2.x), math.max(crop_p1.x, crop_p2.x)
		local min_y, max_y = math.min(crop_p1.y, crop_p2.y), math.max(crop_p1.y, crop_p2.y)
		
		local w = max_x - min_x
		local h = max_y - min_y
		
		if w < 10 or h < 10 then
			mp.osd_message("ОШИБКА: Выделенная область слишком мала. Попробуйте снова.", 3)
			crop_p1 = nil
			crop_p2 = nil
			return
		end
		
		CROP_FILTER = string.format("crop=%d:%d:%d:%d", w, h, min_x, min_y)
		mp.osd_message(string.format("КРОП установлен: %s\nДействие автоматически переключено на CROP", CROP_FILTER), 4)
		
		if ACTION == "COPY" then
			ACTION = "CROP"
		end
	end
end

local function toggle_crop_mode()
	if crop_mode then
		crop_mode = false
		crop_p1 = nil
		crop_p2 = nil
		-- Восстанавливаем OSC
		if osc_was_enabled then
			mp.set_property("osc", "yes")
		end
		mp.osd_message("Режим выделения кропа ОТМЕНЕН", 2)
	else
		crop_mode = true
		crop_p1 = nil
		crop_p2 = nil
		-- Сохраняем состояние OSC и отключаем его
		osc_was_enabled = (mp.get_property("osc") == "yes")
		mp.set_property("osc", "no")
		mp.osd_message("РЕЖИМ КРОПА: OSC отключен. Нажмите Shift + ЛКМ для выбора верхнего левого угла", 4)
	end
end

local function clear_crop()
	CROP_FILTER = nil
	crop_p1 = nil
	crop_p2 = nil
	crop_mode = false
	if osc_was_enabled then
		mp.set_property("osc", "yes")
	end
	mp.osd_message("Фильтр кропа очищен, OSC восстановлен", 2)
end

-- ==========================================
-- ПРИВЯЗКА КЛАВИШ
-- ==========================================

mp.add_key_binding(KEY_CUT, "cut", put_time)
mp.add_key_binding(KEY_CANCEL_CUT, "cancel_cut", cancel_cut)
mp.add_key_binding(KEY_BOOKMARK_ADD, "bookmark_add", bookmark_add)
mp.add_key_binding(KEY_CHANNEL_INC, "channel_inc", channel_inc)
mp.add_key_binding(KEY_CHANNEL_DEC, "channel_dec", channel_dec)
mp.add_key_binding(KEY_CYCLE_ACTION, "cycle_action", cycle_action)

mp.add_key_binding(KEY_CROP_MODE, "toggle_crop_mode", toggle_crop_mode)
mp.add_key_binding("Ctrl+k", "clear_crop", clear_crop)
mp.add_key_binding("shift+mbtn_left", "crop_click", handle_crop_click)

mp.register_event('file-loaded', bookmarks_load)