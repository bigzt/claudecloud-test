-- 游戏外单测：lua5.2 tests/run.lua（在仓库根目录运行）
package.path = "mod/cargo_control/content/scripts/?.lua;" .. package.path

local rules = require "cargo_control.rules"
local controller = require "cargo_control.controller"

local passed, failed = 0, 0
local function test(name, fn)
	local ok, err = pcall(fn)
	if ok then passed = passed + 1 else failed = failed + 1; print("FAIL " .. name .. ": " .. tostring(err)) end
end
local function eq(a, b, msg)
	if a ~= b then error((msg or "") .. " expected " .. tostring(b) .. ", got " .. tostring(a), 2) end
end

-- 假游戏：线路 1 依次停 A(站点组 100, 坐标 0,0)、B(站点组 200, 坐标 1000,0)；
-- 仓库 W 在 (1050,0)，离 B 50 米
local function fakeGame()
	local g = {
		lineData = { [1] = { cargos = { "COAL", "IRON" }, stops = {
			{ sg = 100, unload = {} },
			{ sg = 200, unload = { COAL = true, IRON = true } },
		} } },
		stocks = { W = { COAL = 0, IRON = 0 } },
		pos = { [100] = { 0, 0 }, [200] = { 1000, 0 }, W = { 1050, 0 } },
		commits = 0,
	}
	g.adapter = {
		lines = function() local t = {}; for id in pairs(g.lineData) do t[#t + 1] = id end; return t end,
		readLine = function(id) return g.lineData[id] end,
		stops = function(line)
			local t = {}
			for i, s in ipairs(line.stops) do t[#t + 1] = { index = i, stationGroup = s.sg } end
			return t
		end,
		lineCargos = function(line) return line.cargos end,
		getUnload = function(line, i, c) return line.stops[i].unload[c] == true end,
		setUnload = function(line, i, c, v) line.stops[i].unload[c] = v end,
		commitLine = function() g.commits = g.commits + 1 end,
		stock = function(wh, c) return (g.stocks[wh] or {})[c] or 0 end,
		position = function(e) local p = g.pos[e]; if p then return p[1], p[2] end end,
	}
	return g
end

local function ctx(t)
	t.line = t.line or 1
	t.stationGroup = t.stationGroup or 200
	return t
end

test("无规则时不干预", function()
	eq(rules.decide(rules.newState(), ctx{ cargo = "COAL" }), nil)
end)

test("需求1：仓库禁止存放 = 上限 0", function()
	local s = rules.newState()
	rules.forbid(s, "W", "COAL")
	eq(rules.decide(s, ctx{ cargo = "COAL", warehouse = "W", stock = 0 }), false)
	eq(rules.decide(s, ctx{ cargo = "IRON", warehouse = "W", stock = 0 }), nil)
end)

test("需求2：站点规则 卸 / 不卸，具体货物优先于全部", function()
	local s = rules.newState()
	rules.setStopRule(s, 1, 100, "COAL", rules.UNLOAD)
	rules.setStopRule(s, 1, 200, rules.ALL, rules.KEEP)
	rules.setStopRule(s, 1, 200, "IRON", rules.UNLOAD)
	eq(rules.decide(s, ctx{ stationGroup = 100, cargo = "COAL" }), true)
	eq(rules.decide(s, ctx{ stationGroup = 200, cargo = "COAL" }), false, "全部=不卸")
	eq(rules.decide(s, ctx{ stationGroup = 200, cargo = "IRON" }), true, "具体货物覆盖")
	rules.setStopRule(s, 1, 200, rules.ALL, nil)
	eq(rules.decide(s, ctx{ stationGroup = 200, cargo = "COAL" }), nil)
	eq(rules.getOwnStopRule(s, 1, 200, "IRON"), rules.UNLOAD, "清除一条不影响别的")
end)

test("需求3：限量 + 回差", function()
	local s = rules.newState()
	rules.setWarehouseCap(s, "W", "COAL", 100) -- 回差 10，恢复阈值 90
	local function d(stock, prev)
		return rules.decide(s, ctx{ cargo = "COAL", warehouse = "W", stock = stock, prevAllowed = prev })
	end
	eq(d(50, nil), nil, "未满不干预")
	eq(d(100, nil), false, "满了停卸")
	eq(d(95, false), false, "回差区内保持停卸")
	eq(d(90, false), nil, "降到阈值恢复")
end)

test("站点强制卸货仍受仓库上限约束", function()
	local s = rules.newState()
	rules.setWarehouseCap(s, "W", "COAL", 10)
	rules.setStopRule(s, 1, 200, "COAL", rules.UNLOAD)
	eq(rules.decide(s, ctx{ cargo = "COAL", warehouse = "W", stock = 3 }), true)
	eq(rules.decide(s, ctx{ cargo = "COAL", warehouse = "W", stock = 10 }), false)
end)

test("自动关联：400 米内最近的仓库", function()
	local g = fakeGame()
	local s = rules.newState()
	rules.setWarehouseCap(s, "W", "COAL", 100)
	local binding, links = controller.autoBind(s, g.adapter, { ["100"] = true, ["200"] = true })
	eq(binding["200"], "W")
	eq(binding["100"], nil, "1000 米外不关联")
	eq(#links.W, 1)
end)

test("控制循环：满仓停卸，回落后还原原设置", function()
	local g = fakeGame()
	local s = rules.newState()
	rules.setWarehouseCap(s, "W", "COAL", 100)

	g.stocks.W.COAL = 120
	local ch = controller.tick(s, g.adapter)
	eq(#ch, 1); eq(ch[1].unload, false); eq(ch[1].stopIndex, 2)
	eq(g.lineData[1].stops[2].unload.COAL, false)
	eq(g.lineData[1].stops[2].unload.IRON, true, "其他货物不受影响")
	eq(g.commits, 1)
	eq(s.status.stops["1"]["200"].COAL.allow, false, "界面状态")

	g.stocks.W.COAL = 95
	eq(#controller.tick(s, g.adapter), 0, "回差区内不动")
	eq(g.commits, 1, "没变化不发命令")

	g.stocks.W.COAL = 80
	ch = controller.tick(s, g.adapter)
	eq(#ch, 1); eq(ch[1].unload, true, "还原为原来的卸货")
	eq(s.overrides["1"], nil, "记录已清理")
end)

test("控制循环：全部货物不卸，删除规则后还原", function()
	local g = fakeGame()
	local s = rules.newState()
	rules.setStopRule(s, 1, 200, rules.ALL, rules.KEEP)
	controller.tick(s, g.adapter)
	eq(g.lineData[1].stops[2].unload.COAL, false)
	eq(g.lineData[1].stops[2].unload.IRON, false)
	rules.setStopRule(s, 1, 200, rules.ALL, nil)
	controller.tick(s, g.adapter)
	eq(g.lineData[1].stops[2].unload.COAL, true)
	eq(g.lineData[1].stops[2].unload.IRON, true)
end)

test("调整停靠顺序后规则跟着车站走", function()
	local g = fakeGame()
	local s = rules.newState()
	rules.setStopRule(s, 1, 200, "COAL", rules.KEEP)
	controller.tick(s, g.adapter)
	-- 玩家把两站对调
	local st = g.lineData[1].stops
	st[1], st[2] = st[2], st[1]
	controller.tick(s, g.adapter)
	eq(st[1].sg, 200)
	eq(st[1].unload.COAL, false, "规则仍作用在车站 200")
	eq(s.overrides["1"]["2"], nil, "旧位置的记录已丢弃")
end)

test("存档读回：坏数据给空状态，v1 站点规则丢弃", function()
	eq(rules.load(nil).version, rules.VERSION)
	local s = rules.load({ version = 1, warehouses = { W = { caps = { COAL = 5 } } }, stopRules = { ["1"] = { ["2"] = { COAL = "keep" } } } })
	eq(rules.getWarehouseCap(s, "W", "COAL"), 5)
	eq(next(s.stopRules), nil)
end)

test("删除的线路被清理", function()
	local g = fakeGame()
	local s = rules.newState()
	rules.setStopRule(s, 99, 100, "COAL", rules.KEEP)
	controller.tick(s, g.adapter)
	eq(s.stopRules["99"], nil)
end)

print(string.format("%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
