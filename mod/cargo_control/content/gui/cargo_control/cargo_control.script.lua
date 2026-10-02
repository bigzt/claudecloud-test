-- 入口：挂在游戏底栏上的 react 插件（cargo_control.res.lua 指向这里）。
-- 每帧 onStep 计数，每 TICK_STEPS 帧跑一轮控制循环。
-- 规则保存在存档里（api.gui.game.setGuiSaveData），随存档走。
--
-- 第一版没有图形界面，规则用全局表 cargoctl 设置（游戏控制台里调用），
-- 用法见 docs/DESIGN.md。
function data()
	local MOD = "cargo_control"
	local SAVE_KEY = "cargo_control.state"
	local TICK_STEPS = 60
	local MODULES = { "rules", "controller", "adapter" }

	local function say(line) pcall(debugPrint, "[cargo_control] " .. line) end

	local function installModules()
		for _, name in ipairs(MODULES) do
			local path = MOD .. "::/scripts/cargo_control/" .. name .. ".lua"
			package.preload["cargo_control." .. name] = function() return ug_require(path) end
		end
	end

	local state, rules, controller, adapter

	local function save()
		pcall(api.gui.game.setGuiSaveData, SAVE_KEY, state)
	end

	-- 给控制台用的命令。每个改规则的命令都会立即存档。
	local function makeConsoleApi()
		local function changed(f)
			return function(...)
				f(...)
				save()
				return "ok"
			end
		end
		return {
			-- 需求1/3：仓库上限。cap = 0 禁止，nil 取消
			cap = changed(function(wh, cargo, cap) rules.setWarehouseCap(state, wh, cargo, cap) end),
			forbid = changed(function(wh, cargo) rules.forbid(state, wh, cargo) end),
			-- 站点卸下的货进哪个仓库
			bind = changed(function(stationGroup, wh) rules.bindStation(state, stationGroup, wh) end),
			-- 需求2：线路第 i 站对某货物 "unload" / "keep" / nil
			stop = changed(function(line, i, cargo, mode) rules.setStopRule(state, line, i, cargo, mode) end),
			hysteresis = changed(function(ratio) state.hysteresisRatio = ratio end),
			show = function() return adapter.dump(state) end,
			dumpLine = function(id) adapter.dumpLine(id) end,
			dumpStock = function(id) adapter.dumpStock(id) end,
		}
	end

	local function start()
		installModules()
		rules = require "cargo_control.rules"
		controller = require "cargo_control.controller"
		adapter = require "cargo_control.adapter"
		local ok, saved = pcall(api.gui.game.getGuiSaveData, SAVE_KEY)
		state = rules.load(ok and saved or nil)
		cargoctl = makeConsoleApi() -- 全局，供控制台调用
		say("已加载")
	end

	local function tick()
		controller.forgetMissingLines(state, adapter)
		local changes = controller.tick(state, adapter)
		for _, c in ipairs(changes) do
			say(string.format("线路 %s 第 %d 站 %s -> %s（%s）",
				tostring(c.line), c.stopIndex, c.cargo, c.unload and "卸" or "不卸", c.reason))
		end
		if #changes > 0 then save() end
	end

	local react = ug_require "::/gui/main/react.lua"
	local builtin = ug_require "::/gui/main/builtin.lua"
	local game_bar_widgets = ug_require "::/gui/game_bar/game_bar_widgets.tl"

	local CargoControlPlugin = react.RegisterPluginRecipe(game_bar_widgets.GameBarInfoDisplayExtension, "CargoControlPlugin", function()
		local steps = react.useRef(-1)
		react.onStep(function()
			local n = steps:get()
			if n < 0 then
				local ok, err = pcall(start)
				if not ok then say("启动失败: " .. tostring(err)); steps:set(math.huge); return end
				n = 0
			end
			if n == math.huge then return end
			n = n + 1
			if n >= TICK_STEPS then
				n = 0
				local ok, err = pcall(tick)
				if not ok then say("本轮出错: " .. tostring(err)) end
			end
			steps:set(n)
		end)
		return builtin.BoxLayout{
			orientation = builtin.type.Orientation.Horizontal,
			children = {},
		}
	end)

	return { CargoControlPlugin = CargoControlPlugin }
end
