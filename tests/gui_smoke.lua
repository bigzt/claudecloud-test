-- 界面和游戏脚本的冒烟测试：用桩代替游戏的 react / builtin / api，
-- 把各脚本实际跑一遍、点按钮，确认不报错、发出的事件对。
-- 只验证我们自己的代码路径，不代表游戏里的界面 API 一定这样工作。
-- 运行：lua5.2 tests/gui_smoke.lua（在仓库根目录）
local ROOT = "mod/cargo_control/content/"

local passed, failed = 0, 0
local function test(name, fn)
	local ok, err = pcall(fn)
	if ok then passed = passed + 1 else failed = failed + 1; print("FAIL " .. name .. ": " .. tostring(err)) end
end
local function eq(a, b, msg)
	if a ~= b then error((msg or "") .. " expected " .. tostring(b) .. ", got " .. tostring(a), 2) end
end

---------------------------------------------------------------------------
-- 桩
local sentEvents, buttons, logs = {}, {}, {}

local function node(kind) return function(t) t = t or {}; t.kind = kind; return t end end
local builtin = {
	BoxLayout = node("BoxLayout"), TextView = node("TextView"),
	TextInputField = node("TextInputField"), CheckBox = node("CheckBox"),
	type = { Orientation = { Horizontal = 1, Vertical = 2 } },
}
local states = {}
local react = {
	RegisterRecipe = function(name, fn) return function(params) return fn(params) end end,
	RegisterPluginRecipe = function(ext, name, fn) return function(params) return fn(params) end end,
	CallOriginalRecipe = function(orig, params) return { kind = "original" } end,
	useState = function(v)
		local s = { v = v }
		function s:old() return self.v end
		function s:set(x) self.v = x end
		states[#states + 1] = s
		return s
	end,
}
local engine_react_util = {
	useStepState = function(fn) local v = fn(); return { old = function() return v end } end,
}
local gui_react_util = { makeHorizontalSpacer = function() return { kind = "spacer" } end }
local button_react_util = {
	makeTextButton = function(style, text, onClick, tooltip)
		local b = { kind = "button", text = text, onClick = onClick }
		buttons[#buttons + 1] = b
		return b
	end,
}
local lineReactUtil = { LineCargoDisplay = function() end }
local warehouseEow = { WarehouseEowExtensionPoint = {} }

local guiModules = {
	["::/gui/main/builtin.lua"] = builtin,
	["::/gui/main/react.lua"] = react,
	["::/gui/main/engine_react_util.tl"] = engine_react_util,
	["::/gui/main/gui_react_util.tl"] = gui_react_util,
	["::/gui/main/button_react_util.tl"] = button_react_util,
	["::/gui/line_vehicle_mgmt/line_react_util.tl"] = lineReactUtil,
	["::/gui/entity_window/warehouse/warehouse_eow.script.tl"] = warehouseEow,
}

local loaded = {}
function ug_require(path)
	if guiModules[path] then return guiModules[path] end
	local rel = path:match("^cargo_control::/(.*)$")
	if not rel then error("module not found: " .. path) end
	if loaded[rel] == nil then loaded[rel] = dofile(ROOT .. rel) end
	return loaded[rel]
end

local function loadScript(rel)
	data = nil
	dofile(ROOT .. rel)
	return data()
end

function debugPrint(s) logs[#logs + 1] = s end
function _(s) return s end

-- 游戏世界：线路 10 停靠站点组 100、200；仓库 500 在站点组 200 旁
local gameScriptState = nil
local LINE = { stops = {
	{ stationGroup = 100, stopConfig = { load = { COAL = true } } },
	{ stationGroup = 200, stopConfig = {} },
} }
local CT = { LINE = "LINE", STOCK_LIST = "STOCK_LIST", CONSTRUCTION = "CONSTRUCTION", STATION_GROUP = "SG",
	NAME = "NAME", GAME_TIME = "GT", GAME_SCRIPT = "GS" }
local positions = { [100] = { 0, 0 }, [200] = { 1000, 0 }, [500] = { 1100, 0 } }
local tickCount = 0
api = {
	type = { ComponentType = CT },
	engine = {
		getEntitiesWithComponent = function(c)
			if c == CT.LINE then return { 10 } end
			if c == CT.STOCK_LIST then return { 500 } end
			return {}
		end,
		getComponent = function(e, c)
			if c == CT.LINE and e == 10 then return LINE end
			if c == CT.STOCK_LIST and e == 500 then return { stocks = { { cargoType = "COAL", amount = 480 } } } end
			if c == CT.CONSTRUCTION and positions[e] then
				local p = positions[e]
				local t = {}; for i = 1, 16 do t[i] = 0 end
				t[13], t[14] = p[1], p[2]
				return { transf = t }
			end
			if c == CT.NAME then return { name = "实体" .. e } end
			if c == CT.GAME_TIME then return { tickCount = tickCount } end
			if c == CT.GAME_SCRIPT and e == 1 then return { state = gameScriptState } end
			return nil
		end,
		util = { getWorld = function() return 0 end },
		system = { gameScriptSystem = { getEntityForGameScript = function() return 1 end } },
	},
	cmd = {
		makeScriptingSendEventCmd = function(src, id, name, param) return { id = id, name = name, param = param } end,
		makeLineUpdateCmd = function(line, data) return { line = line, data = data } end,
		sendCommand = function(cmd, cb)
			if cmd.name then sentEvents[#sentEvents + 1] = cmd end
			if cb then cb(nil, true) end
		end,
	},
	res = { cargoTypeRep = {
		getAll = function() return { "COAL", "IRON_ORE" } end,
		find = function(id) return id end,
		get = function(id) return { name = id == "COAL" and "煤" or "铁矿" } end,
	} },
}

-- 游戏脚本状态包装
local gsWrapper = {
	get = function() return gameScriptState end,
	set = function(_, v) gameScriptState = v end,
	subscribeToEvent = function() end,
}

---------------------------------------------------------------------------
local gs = loadScript("cargo_control.script.lua")

local function deliver()
	for _, ev in ipairs(sentEvents) do gs.handleEvent(nil, gsWrapper, "", ev.id, ev.name, ev.param) end
	sentEvents = {}
	tickCount = tickCount + 1
end

test("游戏脚本启动并跑一轮", function()
	gs.update(nil, gsWrapper, 0.1)
	gs.update(nil, gsWrapper, 2.0)
	eq(type(gameScriptState), "table")
	eq(gameScriptState.version, 2)
end)

test("仓库面板：添加货物、设上限、禁止", function()
	local mod = loadScript("gui/cargo_control/warehouse_panel.script.lua")
	assert(mod.WarehousePanelPlugin, "插件未注册")
	states, buttons = {}, {}
	local tree = mod.WarehousePanelPlugin{ entityId = 500 }
	eq(tree.kind, "BoxLayout")
	-- 展开（桩的 useState 每次渲染都新建，所以把已展开的状态喂回去）
	buttons[1].onClick()
	local kept, i = states, 0
	local origUseState = react.useState
	react.useState = function() i = i + 1; return kept[i] end
	buttons = {}
	mod.WarehousePanelPlugin{ entityId = 500 }
	react.useState = origUseState
	local forbid
	for _, b in ipairs(buttons) do if b.text == "禁止" then forbid = b end end
	assert(forbid, "库存里的煤应该有一行")
	forbid.onClick()
	eq(sentEvents[1].name, "CC_SetCap"); eq(sentEvents[1].param.cap, 0)
	sentEvents = {}
	-- 改成上限 500
	gs.handleEvent(nil, gsWrapper, "", "CargoControl", "CC_SetCap", { warehouse = 500, cargo = "COAL", cap = 500 })
	tickCount = tickCount + 1
	gs.update(nil, gsWrapper, 2.0)
	eq(gameScriptState.warehouses["500"].caps.COAL, 500)
	eq(gameScriptState.status.links["500"][1], "200", "自动关联到站点组 200")
end)

test("线路站点行：展开并设置不卸，游戏脚本改线路", function()
	local mod = loadScript("gui/cargo_control/line_stops.script.lua")
	local replaced
	mod.doReplace({ ReplaceRecipe = function(orig, new) replaced = new end })
	assert(replaced, "没有替换 LineCargoDisplay")

	-- 线路列表里的调用：原样返回
	eq(replaced{ lineEntity = 10 }.child.kind, "original")

	-- 第 2 站（stopIndex 0 起）
	states, buttons = {}, {}
	replaced{ lineEntity = 10, stopIndex = 1, stopCargoDisplay = true }
	buttons[1].onClick() -- 展开
	-- 用同一个 useState 再渲染：替换 useState 让它返回已展开的状态
	local opened = states[1]
	local origUseState = react.useState
	react.useState = function() return opened end
	buttons = {}
	replaced{ lineEntity = 10, stopIndex = 1, stopCargoDisplay = true }
	react.useState = origUseState

	local keepCoal
	local seenAll = 0
	for _, b in ipairs(buttons) do
		if b.text == "不卸" then
			seenAll = seenAll + 1
			if seenAll == 2 then keepCoal = b end -- 第一行是「全部货物」，第二行是煤
		end
	end
	assert(keepCoal, "应有煤的「不卸」按钮")
	keepCoal.onClick()
	eq(sentEvents[1].param.stationGroup, 200)
	eq(sentEvents[1].param.cargo, "COAL")
	deliver()
	gs.update(nil, gsWrapper, 2.0)
	eq(LINE.stops[2].stopConfig.unload.COAL, false, "线路第 2 站煤设为不卸")
	eq(gameScriptState.status.stops["10"]["200"].COAL.allow, false)
end)

test("没有出错日志", function()
	for _, l in ipairs(logs) do
		assert(not l:find("出错"), l)
	end
end)

print(string.format("%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
