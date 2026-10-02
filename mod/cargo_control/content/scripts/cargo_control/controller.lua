-- 控制循环：定期读仓库库存，按 rules.decide() 的结论改线路的站点卸货设置。
--
-- 它只通过注入的 adapter 接触游戏（见 adapter.lua），所以可用假 adapter 单测。
-- adapter 需要提供：
--   lines()                         -> { lineId, ... }
--   readLine(lineId)                -> line（可修改的副本）
--   stops(line)                     -> { { index = i, stationGroup = id }, ... }
--   getUnload(line, i, cargo)       -> true / false（游戏当前设置）
--   setUnload(line, i, cargo, bool)    改副本
--   commitLine(lineId, line)           把副本写回游戏（一条命令）
--   stock(warehouse, cargo)         -> 数量
--
-- 被改过的设置会把游戏原值记在 state.overrides 里，规则撤销后还原，
-- 这样卸载本 mod 或删除规则不会把线路留在被改过的状态。
local rules = require "cargo_control.rules"

local controller = {}

local function key(id) return tostring(id) end

local function overridesOf(state)
	state.overrides = state.overrides or {}
	return state.overrides
end

-- 这一站需要关心哪些货物：站点规则里出现的 + 绑定仓库有上限的 + 曾经改过的
local function cargosFor(state, lineId, stopIndex, stationGroup)
	local set, list = {}, {}
	local function add(c)
		if not set[c] then set[c] = true; list[#list + 1] = c end
	end
	local l = state.stopRules[key(lineId)]
	local s = l and l[key(stopIndex)]
	if s then for c in pairs(s) do add(c) end end
	local wh = rules.warehouseOfStation(state, stationGroup)
	local w = wh and state.warehouses[key(wh)]
	if w and w.caps then for c in pairs(w.caps) do add(c) end end
	local o = overridesOf(state)[key(lineId)]
	o = o and o[key(stopIndex)]
	if o then for c in pairs(o) do add(c) end end
	table.sort(list) -- 固定顺序，保证每次结果一致
	return list
end

-- 跑一轮。返回本轮改动的列表（用于日志 / 界面），每项
-- { line, stopIndex, cargo, unload, reason }
function controller.tick(state, adapter)
	local changes = {}
	local overrides = overridesOf(state)
	local lineIds = adapter.lines()
	table.sort(lineIds, function(a, b) return key(a) < key(b) end)

	for _, lineId in ipairs(lineIds) do
		local line = adapter.readLine(lineId)
		local dirty = false
		if line ~= nil then
			for _, stop in ipairs(adapter.stops(line)) do
				for _, cargo in ipairs(cargosFor(state, lineId, stop.index, stop.stationGroup)) do
					local lo = overrides[key(lineId)]
					local so = lo and lo[key(stop.index)]
					local rec = so and so[cargo]

					local wh = rules.warehouseOfStation(state, stop.stationGroup)
					local allow, reason = rules.decide(state, {
						line = lineId,
						stopIndex = stop.index,
						stationGroup = stop.stationGroup,
						cargo = cargo,
						stock = wh and adapter.stock(wh, cargo) or nil,
						prevAllowed = rec and rec.applied,
					})

					local current = adapter.getUnload(line, stop.index, cargo)
					local want
					if allow == nil then
						-- 不干预：如果之前改过，还原为原值并丢掉记录
						if rec then
							want = rec.original
							so[cargo] = nil
							if next(so) == nil then lo[key(stop.index)] = nil end
							if next(lo) == nil then overrides[key(lineId)] = nil end
							reason = "还原：" .. reason
						end
					else
						if not rec then
							lo = lo or {}; overrides[key(lineId)] = lo
							so = so or {}; lo[key(stop.index)] = so
							rec = { original = current }
							so[cargo] = rec
						end
						rec.applied = allow
						want = allow
					end

					if want ~= nil and want ~= current then
						adapter.setUnload(line, stop.index, cargo, want)
						dirty = true
						changes[#changes + 1] = {
							line = lineId, stopIndex = stop.index, cargo = cargo,
							unload = want, reason = reason,
						}
					end
				end
			end
			if dirty then adapter.commitLine(lineId, line) end
		end
	end
	return changes
end

-- 线路被删除后清理残留记录
function controller.forgetMissingLines(state, adapter)
	local alive = {}
	for _, id in ipairs(adapter.lines()) do alive[key(id)] = true end
	for id in pairs(overridesOf(state)) do
		if not alive[id] then state.overrides[id] = nil end
	end
	for id in pairs(state.stopRules) do
		if not alive[id] then state.stopRules[id] = nil end
	end
end

return controller
