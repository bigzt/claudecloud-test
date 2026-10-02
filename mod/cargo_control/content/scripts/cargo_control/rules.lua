-- 规则引擎（纯 Lua，不调用任何游戏 API，可在游戏外单测）。
--
-- 三条需求在这里统一成一个判断：线路 line 停靠站点组 stationGroup 时，
-- 货物 cargo 要不要卸？
--
--   1. 仓库禁止存放某货物      = 仓库对该货物上限为 0
--   2. 线路在某站卸/不卸某货物 = 站点规则 "unload" / "keep"
--   3. 仓库限量，超过不卸货    = 仓库对该货物上限为 n，库存 >= n 停卸，
--                                回落到 n - 回差 以下再恢复（防止来回抖动）
--
-- 站点规则按「线路 + 站点组」存，不按站序号，所以线路增删、调整停靠顺序后
-- 规则仍然跟着车站走。同一线路多次停靠同一车站时共用一条规则。
--
-- decide() 返回 true（卸）、false（不卸）或 nil（不干预，沿用游戏原设置）。
local rules = {}

rules.VERSION = 2

rules.UNLOAD = "unload" -- 在此站卸下（仍受仓库上限约束）
rules.KEEP = "keep"     -- 在此站不卸
rules.ALL = "*"         -- 站点规则里代表「全部货物」；具体货物的规则优先

function rules.newState()
	return {
		version = rules.VERSION,
		-- warehouses[仓库ID] = { caps = { [货物] = 上限 } }
		-- 上限 nil = 不限，0 = 禁止存放，n > 0 = 最多存 n
		warehouses = {},
		-- stationWarehouse[站点组ID] = 仓库ID（手动指定；没有就用自动关联）
		stationWarehouse = {},
		-- stopRules[线路ID][站点组ID][货物 或 "*"] = "unload" | "keep"
		stopRules = {},
		-- 回差：停卸后，库存要降到 上限 - 回差 才恢复卸货
		hysteresisRatio = 0.1,
	}
end

-- 存档序列化后数字键可能变成字符串，统一用字符串做键
local function key(id) return tostring(id) end
rules.key = key

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
	prune(state.warehouses, key(warehouse))
end

function rules.forbid(state, warehouse, cargo)
	rules.setWarehouseCap(state, warehouse, cargo, 0)
end

function rules.getWarehouseCap(state, warehouse, cargo)
	local wh = state.warehouses[key(warehouse)]
	return wh and wh.caps and wh.caps[cargo]
end

function rules.warehouseCaps(state, warehouse)
	local wh = state.warehouses[key(warehouse)]
	return (wh and wh.caps) or {}
end

function rules.bindStation(state, stationGroup, warehouse)
	state.stationWarehouse[key(stationGroup)] = warehouse and key(warehouse) or nil
end

-- autoBinding：控制器按距离算出的 { [站点组] = 仓库 }，手动指定优先
function rules.warehouseOfStation(state, stationGroup, autoBinding)
	local k = key(stationGroup)
	return state.stationWarehouse[k] or (autoBinding and autoBinding[k])
end

-- mode = "unload" | "keep" | nil（清除）；cargo 可以是 rules.ALL
function rules.setStopRule(state, line, stationGroup, cargo, mode)
	assert(mode == nil or mode == rules.UNLOAD or mode == rules.KEEP, "未知的站点规则: " .. tostring(mode))
	local l = sub(state.stopRules, key(line))
	local s = sub(l, key(stationGroup))
	s[cargo] = mode
	prune(l, key(stationGroup))
	prune(state.stopRules, key(line))
end

-- 只看这一条（不回落到 "*"），给界面显示用
function rules.getOwnStopRule(state, line, stationGroup, cargo)
	local l = state.stopRules[key(line)]
	local s = l and l[key(stationGroup)]
	return s and s[cargo]
end

-- 实际生效的：具体货物 > "*"
function rules.getStopRule(state, line, stationGroup, cargo)
	local l = state.stopRules[key(line)]
	local s = l and l[key(stationGroup)]
	if not s then return nil end
	if s[cargo] ~= nil then return s[cargo] end
	return s[rules.ALL]
end

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

-- ctx = { line, stationGroup, cargo, warehouse, stock, prevAllowed }
-- 返回 allow(true/false/nil), reason(string)
function rules.decide(state, ctx)
	local mode = rules.getStopRule(state, ctx.line, ctx.stationGroup, ctx.cargo)
	if mode == rules.KEEP then
		return false, "站点规则：不卸"
	end

	local wh = ctx.warehouse
	local accepts = rules.warehouseAccepts(state, wh, ctx.cargo, ctx.stock, ctx.prevAllowed)
	if accepts == false then
		local cap = rules.getWarehouseCap(state, wh, ctx.cargo)
		if cap == 0 then return false, "仓库禁止存放" end
		return false, string.format("仓库已满 %d/%d", ctx.stock or 0, cap)
	end

	if mode == rules.UNLOAD then
		return true, "站点规则：卸货"
	end
	if accepts == true then
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
	if saved.version < 2 then
		-- v1 的站点规则按站序号存，无法可靠换算成站点组，丢弃
		state.stopRules = {}
	end
	state.version = rules.VERSION
	return state
end

return rules
