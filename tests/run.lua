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

-- 假游戏：线路 L1 依次停 A(站点组 100)、B(站点组 200)；B 站旁边是仓库 W
local function fakeGame()
	local g = {
		lineData = { [1] = { stops = { { sg = 100, unload = {} }, { sg = 200, unload = { COAL = true, IRON = true } } } } },
		stocks = { W = { COAL = 0, IRON = 0 } },
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
		getUnload = function(line, i, c) return line.stops[i].unload[c] == true end,
		setUnload = function(line, i, c, v) line.stops[i].unload[c] = v end,
		commitLine = function() g.commits = g.commits + 1 end,
		stock = function(wh, c) return (g.stocks[wh] or {})[c] or 0 end,
	}
	return g
end

test("无规则时不干预", function()
	local s = rules.newState()
	local allow = rules.decide(s, { line = 1, stopIndex = 2, stationGroup = 200, cargo = "COAL" })
	eq(allow, nil)
end)

test("需求1：仓库禁止存放 = 上限 0", function()
	local s = rules.newState()
	rules.bindStation(s, 200, "W")
	rules.forbid(s, "W", "COAL")
	eq(rules.decide(s, { line = 1, stopIndex = 2, stationGroup = 200, cargo = "COAL", stock = 0 }), false)
	eq(rules.decide(s, { line = 1, stopIndex = 2, stationGroup = 200, cargo = "IRON", stock = 0 }), nil)
end)

test("需求2：站点规则 卸 / 不卸", function()
	local s = rules.newState()
	rules.setStopRule(s, 1, 1, "COAL", rules.UNLOAD)
	rules.setStopRule(s, 1, 2, "COAL", rules.KEEP)
	eq(rules.decide(s, { line = 1, stopIndex = 1, stationGroup = 100, cargo = "COAL" }), true)
	eq(rules.decide(s, { line = 1, stopIndex = 2, stationGroup = 200, cargo = "COAL" }), false)
	rules.setStopRule(s, 1, 2, "COAL", nil)
	eq(rules.decide(s, { line = 1, stopIndex = 2, stationGroup = 200, cargo = "COAL" }), nil)
	eq(next(s.stopRules[tostring(1)] or {}) ~= nil, true, "清除一站后另一站规则保留")
end)

test("需求3：限量 + 回差", function()
	local s = rules.newState()
	rules.bindStation(s, 200, "W")
	rules.setWarehouseCap(s, "W", "COAL", 100) -- 回差 10，恢复阈值 90
	local function d(stock, prev)
		return rules.decide(s, { line = 1, stopIndex = 2, stationGroup = 200, cargo = "COAL", stock = stock, prevAllowed = prev })
	end
	eq(d(50, nil), nil, "未满不干预")
	eq(d(100, nil), false, "满了停卸")
	eq(d(95, false), false, "回差区内保持停卸")
	eq(d(90, false), nil, "降到阈值恢复")
end)

test("站点强制卸货仍受仓库上限约束", function()
	local s = rules.newState()
	rules.bindStation(s, 200, "W")
	rules.setWarehouseCap(s, "W", "COAL", 10)
	rules.setStopRule(s, 1, 2, "COAL", rules.UNLOAD)
	eq(rules.decide(s, { line = 1, stopIndex = 2, stationGroup = 200, cargo = "COAL", stock = 3 }), true)
	eq(rules.decide(s, { line = 1, stopIndex = 2, stationGroup = 200, cargo = "COAL", stock = 10 }), false)
end)

test("控制循环：满仓停卸，回落后还原原设置", function()
	local g = fakeGame()
	local s = rules.newState()
	rules.bindStation(s, 200, "W")
	rules.setWarehouseCap(s, "W", "COAL", 100)

	g.stocks.W.COAL = 120
	local ch = controller.tick(s, g.adapter)
	eq(#ch, 1); eq(ch[1].unload, false)
	eq(g.lineData[1].stops[2].unload.COAL, false)
	eq(g.lineData[1].stops[2].unload.IRON, true, "其他货物不受影响")
	eq(g.commits, 1)

	g.stocks.W.COAL = 95
	eq(#controller.tick(s, g.adapter), 0, "回差区内不动")
	eq(g.commits, 1, "没变化不发命令")

	g.stocks.W.COAL = 80
	ch = controller.tick(s, g.adapter)
	eq(#ch, 1); eq(ch[1].unload, true, "还原为原来的卸货")
	eq(s.overrides[tostring(1)], nil, "记录已清理")
end)

test("控制循环：删除规则后还原", function()
	local g = fakeGame()
	local s = rules.newState()
	rules.setStopRule(s, 1, 2, "IRON", rules.KEEP)
	controller.tick(s, g.adapter)
	eq(g.lineData[1].stops[2].unload.IRON, false)
	rules.setStopRule(s, 1, 2, "IRON", nil)
	controller.tick(s, g.adapter)
	eq(g.lineData[1].stops[2].unload.IRON, true)
end)

test("存档读回：坏数据给空状态，旧数据补字段", function()
	eq(rules.load(nil).version, rules.VERSION)
	local s = rules.load({ version = 1, warehouses = { W = { caps = { COAL = 5 } } } })
	eq(rules.getWarehouseCap(s, "W", "COAL"), 5)
	eq(type(s.stopRules), "table")
end)

test("删除的线路被清理", function()
	local g = fakeGame()
	local s = rules.newState()
	rules.setStopRule(s, 99, 1, "COAL", rules.KEEP)
	controller.forgetMissingLines(s, g.adapter)
	eq(s.stopRules["99"], nil)
end)

print(string.format("%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
