-- 控制循环（在游戏脚本里每 2 秒跑一次）：读仓库库存，按 rules.decide()
-- 的结论改线路的站点卸货设置。
--
-- 只通过注入的 adapter 接触游戏（见 adapter.lua），所以可用假 adapter 单测。
-- adapter 需要提供：
--   lines()                         -> { lineId, ... }
--   readLine(lineId)                -> line（可修改的副本）
--   stops(line)                     -> { { index = i, stationGroup = id }, ... }   i 从 1 开始
--   lineCargos(line)                -> { 货物, ... }   线路运的货物（拿不到就给 {}）
--   getUnload(line, i, cargo)       -> true / false（游戏当前设置）
--   setUnload(line, i, cargo, bool)    改副本
--   commitLine(lineId, line)           把副本写回游戏（一条命令）
--   stock(warehouse, cargo)         -> 数量
--   position(entity)                -> x, y（拿不到给 nil），用于自动关联车站和仓库
--
-- 被改过的设置会把游戏原值记在 state.overrides 里，规则撤销后还原。
local rules = (ug_require and ug_require("cargo_control::/scripts/cargo_control/rules.lua"))
	or require "cargo_control.rules"

local controller = {}

local key = rules.key

controller.DEFAULT_LINK_RADIUS = 400 -- 米：车站与仓库距离在此以内视为关联

local function sortedKeys(t)
	local list = {}
	for k in pairs(t) do list[#list + 1] = k end
	table.sort(list, function(a, b) return tostring(a) < tostring(b) end)
	return list
end

-- 每个站点组关联到最近的、有规则的仓库
function controller.autoBind(state, adapter, stationGroups)
	local radius = state.linkRadius or controller.DEFAULT_LINK_RADIUS
	local whPos = {}
	for _, wh in ipairs(sortedKeys(state.warehouses)) do
		local x, y = adapter.position(tonumber(wh) or wh)
		if x then whPos[#whPos + 1] = { id = wh, x = x, y = y } end
	end
	local binding, links = {}, {}
	if #whPos == 0 then return binding, links end
	for _, sg in ipairs(sortedKeys(stationGroups)) do
		local x, y = adapter.position(tonumber(sg) or sg)
		if x then
			local best, bestD = nil, radius * radius
			for _, w in ipairs(whPos) do
				local d = (w.x - x) ^ 2 + (w.y - y) ^ 2
				if d <= bestD then best, bestD = w.id, d end
			end
			if best then
				binding[sg] = best
				links[best] = links[best] or {}
				table.insert(links[best], sg)
			end
		end
	end
	return binding, links
end

local function cargosFor(state, adapter, line, lineId, stopIndex, sg, wh)
	local set, list = {}, {}
	local function add(c)
		if c ~= rules.ALL and not set[c] then set[c] = true; list[#list + 1] = c end
	end
	local l = state.stopRules[key(lineId)]
	local s = l and l[key(sg)]
	local wildcard = false
	if s then
		for c in pairs(s) do
			if c == rules.ALL then wildcard = true else add(c) end
		end
	end
	if wildcard then
		for _, c in ipairs(adapter.lineCargos(line)) do add(c) end
	end
	for c in pairs(rules.warehouseCaps(state, wh)) do add(c) end
	local o = state.overrides[key(lineId)]
	o = o and o[key(stopIndex)]
	if o then for c in pairs(o) do add(c) end end
	table.sort(list)
	return list
end

-- 跑一轮。返回本轮改动列表 { line, stopIndex, stationGroup, cargo, unload, reason }。
-- 同时把给界面看的状态写进 state.status。
function controller.tick(state, adapter)
	state.overrides = state.overrides or {}
	local overrides = state.overrides
	local changes = {}
	local status = { stops = {}, links = {} }

	local lineIds = adapter.lines()
	table.sort(lineIds, function(a, b) return key(a) < key(b) end)

	local lines, allSg = {}, {}
	for _, lineId in ipairs(lineIds) do
		local line = adapter.readLine(lineId)
		if line ~= nil then
			lines[#lines + 1] = { id = lineId, line = line, stops = adapter.stops(line) }
			for _, st in ipairs(lines[#lines].stops) do allSg[key(st.stationGroup)] = true end
		end
	end

	local autoBinding, links = controller.autoBind(state, adapter, allSg)
	status.links = links

	for _, entry in ipairs(lines) do
		local lineId, line = entry.id, entry.line
		local lk = key(lineId)
		local dirty = false

		-- 站序变了（这一位置已经不是原来的车站）的记录无法可靠还原，丢掉
		local lo = overrides[lk]
		if lo then
			for idx, so in pairs(lo) do
				local st = entry.stops[tonumber(idx)]
				for cargo, rec in pairs(so) do
					if not st or key(st.stationGroup) ~= rec.sg then so[cargo] = nil end
				end
				if next(so) == nil then lo[idx] = nil end
			end
			if next(lo) == nil then overrides[lk] = nil end
		end

		for _, stop in ipairs(entry.stops) do
			local sk = key(stop.stationGroup)
			local wh = rules.warehouseOfStation(state, stop.stationGroup, autoBinding)
			for _, cargo in ipairs(cargosFor(state, adapter, line, lineId, stop.index, stop.stationGroup, wh)) do
				lo = overrides[lk]
				local so = lo and lo[key(stop.index)]
				local rec = so and so[cargo]

				local allow, reason = rules.decide(state, {
					line = lineId,
					stationGroup = stop.stationGroup,
					cargo = cargo,
					warehouse = wh,
					stock = wh and adapter.stock(tonumber(wh) or wh, cargo) or nil,
					prevAllowed = rec and rec.applied,
				})

				local current = adapter.getUnload(line, stop.index, cargo)
				local want
				if allow == nil then
					if rec then
						want = rec.original
						so[cargo] = nil
						if next(so) == nil then lo[key(stop.index)] = nil end
						if next(lo) == nil then overrides[lk] = nil end
					end
				else
					if not rec then
						lo = lo or {}; overrides[lk] = lo
						so = so or {}; lo[key(stop.index)] = so
						rec = { original = current, sg = sk }
						so[cargo] = rec
					end
					rec.applied = allow
					want = allow
				end

				local ss = status.stops[lk] or {}; status.stops[lk] = ss
				local sc = ss[sk] or {}; ss[sk] = sc
				sc[cargo] = { allow = allow, reason = reason }

				if want ~= nil and want ~= current then
					adapter.setUnload(line, stop.index, cargo, want)
					dirty = true
					changes[#changes + 1] = {
						line = lineId, stopIndex = stop.index, stationGroup = stop.stationGroup,
						cargo = cargo, unload = want, reason = reason,
					}
				end
			end
		end
		if dirty then adapter.commitLine(lineId, line) end
	end

	-- 删除的线路：清掉规则和记录
	local alive = {}
	for _, id in ipairs(lineIds) do alive[key(id)] = true end
	for id in pairs(overrides) do if not alive[id] then overrides[id] = nil end end
	for id in pairs(state.stopRules) do if not alive[id] then state.stopRules[id] = nil end end

	state.status = status
	return changes
end

return controller
