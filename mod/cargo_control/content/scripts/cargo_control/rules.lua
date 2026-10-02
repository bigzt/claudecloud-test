-- 规则引擎（纯 Lua，不调用任何游戏 API，可在游戏外单测）。
--
-- 三条需求在这里统一成一个判断：某条线路 line 的第 stopIndex 站，
-- 车辆到站时，货物 cargo 要不要卸？
--
--   1. 仓库禁止存放某货物      = 仓库对该货物上限为 0
--   2. 线路在某站卸/不卸某货物 = 站点规则 "unload" / "keep"
--   3. 仓库限量，超过不卸货    = 仓库对该货物上限为 n，库存 >= n 停卸，
--                                回落到 n - 回差 以下再恢复（防止来回抖动）
--
-- decide() 返回 true（卸）、false（不卸）或 nil（不干预，沿用游戏原设置）。
local rules = {}

rules.VERSION = 1

-- 站点规则的取值
rules.UNLOAD = "unload" -- 在此站强制卸下（仍受仓库上限约束）
rules.KEEP = "keep"     -- 在此站绝不卸下

function rules.newState()
	return {
		version = rules.VERSION,
		-- warehouses[仓库实体ID] = { caps = { [货物ID] = 上限 } }
		-- 上限 nil = 不限，0 = 禁止存放，n > 0 = 最多存 n
		warehouses = {},
		-- stationWarehouse[站点组实体ID] = 仓库实体ID
		-- 站点卸下的货进哪个仓库。游戏里查不到时由玩家手动绑定。
		stationWarehouse = {},
		-- stopRules[线路ID][站序号][货物ID] = "unload" | "keep"
		stopRules = {},
		-- 回差：停卸后，库存要降到 上限 - 回差 才恢复卸货
		hysteresisRatio = 0.1,
	}
end

local function key(id)
	-- 存档序列化后数字键可能变成字符串，统一用字符串做键
	return tostring(id)
end

local function sub(t, k)
	local v = t[k]
	if v == nil then
		v = {}
		t[k] = v
	end
	return v
end

local function prune(t, k)
	if t[k] ~= nil and next(t[k]) == nil then t[k] = nil end
end

-- 设置仓库对某货物的上限。cap = nil 取消限制，0 = 禁止。
function rules.setWarehouseCap(state, warehouse, cargo, cap)
	if cap ~= nil then
		assert(type(cap) == "number" and cap >= 0, "上限必须是 >= 0 的数字或 nil")
		cap = math.floor(cap)
	end
	local wh = sub(state.warehouses, key(warehouse))
	local caps = sub(wh, "caps")
	caps[cargo] = cap
	prune(wh, "caps")
	if wh.caps == nil then state.warehouses[key(warehouse)] = nil end
end

function rules.forbid(state, warehouse, cargo)
	rules.setWarehouseCap(state, warehouse, cargo, 0)
end

function rules.getWarehouseCap(state, warehouse, cargo)
	local wh = state.warehouses[key(warehouse)]
	return wh and wh.caps and wh.caps[cargo]
end

function rules.bindStation(state, stationGroup, warehouse)
	state.stationWarehouse[key(stationGroup)] = warehouse and key(warehouse) or nil
end

function rules.warehouseOfStation(state, stationGroup)
	return state.stationWarehouse[key(stationGroup)]
end

-- mode = "unload" | "keep" | nil（清除）
function rules.setStopRule(state, line, stopIndex, cargo, mode)
	assert(mode == nil or mode == rules.UNLOAD or mode == rules.KEEP, "未知的站点规则: " .. tostring(mode))
	local l = sub(state.stopRules, key(line))
	local s = sub(l, key(stopIndex))
	s[cargo] = mode
	prune(l, key(stopIndex))
	prune(state.stopRules, key(line))
end

function rules.getStopRule(state, line, stopIndex, cargo)
	local l = state.stopRules[key(line)]
	local s = l and l[key(stopIndex)]
	return s and s[cargo]
end

-- 恢复卸货的库存阈值
function rules.resumeLevel(state, cap)
	local gap = math.max(1, math.floor(cap * (state.hysteresisRatio or 0)))
	return math.max(0, cap - gap)
end

-- 仓库是否还收这种货。prevAllowed 是上一次的结论，用于回差。
-- 返回 true / false，或 nil 表示该仓库对此货物没有规则。
function rules.warehouseAccepts(state, warehouse, cargo, stock, prevAllowed)
	if warehouse == nil then return nil end
	local cap = rules.getWarehouseCap(state, warehouse, cargo)
	if cap == nil then return nil end
	if cap == 0 then return false end
	stock = stock or 0
	if stock >= cap then return false end
	if prevAllowed == false and stock > rules.resumeLevel(state, cap) then
		return false
	end
	return true
end

-- 核心判断。ctx = {
--   line, stopIndex, stationGroup, cargo,
--   stock        = 仓库当前该货物库存（可为 nil）,
--   prevAllowed  = 上次判断结果（可为 nil）,
-- }
-- 返回 allow(true/false/nil), reason(string)
function rules.decide(state, ctx)
	local mode = rules.getStopRule(state, ctx.line, ctx.stopIndex, ctx.cargo)
	if mode == rules.KEEP then
		return false, "站点规则：此站不卸"
	end

	local wh = rules.warehouseOfStation(state, ctx.stationGroup)
	local accepts = rules.warehouseAccepts(state, wh, ctx.cargo, ctx.stock, ctx.prevAllowed)
	if accepts == false then
		local cap = rules.getWarehouseCap(state, wh, ctx.cargo)
		if cap == 0 then return false, "仓库禁止存放" end
		return false, string.format("仓库已满（%d/%d）", ctx.stock or 0, cap)
	end

	if mode == rules.UNLOAD then
		return true, "站点规则：此站卸货"
	end
	if accepts == true then
		-- 仓库有上限且未满：不强制卸，交给游戏原设置
		return nil, "仓库未满"
	end
	return nil, "无规则"
end

-- 存档读回后的修复：补字段、升级版本。读不懂就给新的空状态。
function rules.load(saved)
	if type(saved) ~= "table" or type(saved.version) ~= "number" then
		return rules.newState()
	end
	local state = rules.newState()
	for k, v in pairs(saved) do state[k] = v end
	state.version = rules.VERSION
	return state
end

return rules
