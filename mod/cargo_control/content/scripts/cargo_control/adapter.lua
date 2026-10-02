-- 游戏适配层：controller.lua 需要的接口，用 TF3 的 api.* 实现。
--
-- 可信度标记（来源见 docs/DESIGN.md「API 依据」）：
--   [已知]   官方脚本文档或已上架的 TF3 mod 用过的名字
--   [待验证] 名字已知，但字段布局/取值没核实，第一次进游戏要用 dump 确认
--
-- 所有 [待验证] 的部分都集中在下面的 FIELDS 表里。进游戏后在控制台执行
--   cargoctl.dumpLine(<线路ID>)   和   cargoctl.dumpStock(<仓库ID>)
-- 看日志里的真实结构，再改 FIELDS，其他文件不用动。
local adapter = {}

local function ct() return api.type.ComponentType end -- [已知]

local FIELDS = {}

-- [待验证] Line.Stop.stopConfig：TF3 新增的每站配置。线路窗口里有
-- “按货物设置装/卸”和“到站强制卸货”，推测就存在这里。
-- 下面按「stopConfig.unload[货物] = true/false」写，进游戏 dump 后改。
function FIELDS.getUnload(stop, cargo)
	local cfg = stop.stopConfig
	if cfg == nil or cfg.unload == nil then return true end
	local v = cfg.unload[cargo]
	if v == nil then return true end
	return v and true or false
end

function FIELDS.setUnload(stop, cargo, value)
	stop.stopConfig = stop.stopConfig or {}
	stop.stopConfig.unload = stop.stopConfig.unload or {}
	stop.stopConfig.unload[cargo] = value
end

-- [待验证] STOCK_LIST：仓库/工业的库存。makeStockSetCargoAmountCmd(entity,
-- stockId, amount, cargoType: string) 说明每个 stock 有 id、数量、货物类型。
-- 这里按 stocks[i] = { cargoType = "COAL", amount = n } 求和。
function FIELDS.stock(stockList, cargo)
	local total = 0
	for _, s in pairs(stockList.stocks or {}) do
		if s.cargoType == cargo then total = total + (s.amount or 0) end
	end
	return total
end

adapter.FIELDS = FIELDS

---------------------------------------------------------------------------
-- controller 接口

function adapter.lines()
	-- [已知] getEntitiesWithComponent / ComponentType.LINE
	local ids = api.engine.getEntitiesWithComponent(ct().LINE)
	local out = {}
	for i = 1, #ids do out[i] = ids[i] end
	return out
end

function adapter.readLine(lineId)
	-- [已知] getComponent(entity, LINE) -> Engine.Component.Line
	local ok, line = pcall(api.engine.getComponent, lineId, ct().LINE)
	if ok then return line end
	return nil
end

function adapter.stops(line)
	local out = {}
	-- [已知] Line.stops，Stop.stationGroup
	for i = 1, #line.stops do
		out[i] = { index = i, stationGroup = line.stops[i].stationGroup }
	end
	return out
end

function adapter.getUnload(line, i, cargo)
	return FIELDS.getUnload(line.stops[i], cargo)
end

function adapter.setUnload(line, i, cargo, value)
	FIELDS.setUnload(line.stops[i], cargo, value)
end

function adapter.commitLine(lineId, line)
	-- [已知] makeLineUpdateCmd(lineEntity, data: Engine.Component.Line)
	api.cmd.sendCommand(api.cmd.makeLineUpdateCmd(lineId, line), function(_, ok)
		if not ok then pcall(debugPrint, "[cargo_control] 线路更新失败: " .. tostring(lineId)) end
	end)
end

function adapter.stock(warehouse, cargo)
	local id = tonumber(warehouse) or warehouse
	local ok, sl = pcall(api.engine.getComponent, id, ct().STOCK_LIST)
	if not ok or sl == nil then return 0 end
	return FIELDS.stock(sl, cargo)
end

---------------------------------------------------------------------------
-- 调试：把结构打到日志，用来填 FIELDS

local function dump(v, indent, seen, depth)
	indent, seen, depth = indent or "", seen or {}, depth or 0
	local t = type(v)
	if t ~= "table" and t ~= "userdata" then return tostring(v) end
	if seen[v] or depth > 6 then return "<...>" end
	seen[v] = true
	local parts = {}
	local ok = pcall(function()
		for k, x in pairs(v) do
			parts[#parts + 1] = indent .. "  " .. tostring(k) .. " = " .. dump(x, indent .. "  ", seen, depth + 1)
		end
	end)
	if not ok or #parts == 0 then return tostring(v) end
	return "{\n" .. table.concat(parts, "\n") .. "\n" .. indent .. "}"
end
adapter.dump = dump

function adapter.dumpLine(lineId)
	pcall(debugPrint, "[cargo_control] LINE " .. tostring(lineId) .. " = " .. dump(adapter.readLine(lineId)))
end

function adapter.dumpStock(entity)
	local ok, sl = pcall(api.engine.getComponent, entity, ct().STOCK_LIST)
	pcall(debugPrint, "[cargo_control] STOCK_LIST " .. tostring(entity) .. " = " .. (ok and dump(sl) or "无"))
end

return adapter
