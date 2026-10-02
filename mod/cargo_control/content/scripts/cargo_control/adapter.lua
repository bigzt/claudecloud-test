-- 游戏适配层：controller.lua 需要的接口，用 TF3 的 api.* 实现。
--
-- 可信度标记（来源见 docs/DESIGN.md「API 依据」）：
--   [已知]   官方脚本文档或已上架的 TF3 mod 用过的名字
--   [待验证] 名字已知，但字段布局/取值没核实，第一次进游戏要用 dump 确认
--
-- 数据结构上 [待验证] 的部分都集中在下面的 FIELDS 表里。mod 启动后会把
-- 第一条线路和第一个仓库的结构打到日志（见 game_script.lua 的 probe），
-- 照着日志改 FIELDS，其他文件不用动。
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
-- 这里按 stocks[i] = { cargoType = "COAL", amount = n } 汇总成 { [货物] = 数量 }。
function FIELDS.stocks(stockList)
	local out = {}
	for _, s in pairs(stockList.stocks or {}) do
		if s.cargoType ~= nil then
			out[s.cargoType] = (out[s.cargoType] or 0) + (s.amount or 0)
		end
	end
	return out
end

-- [待验证] 线路运哪些货：推测在 stopConfig.load（各站装货的货物）里，
-- 拿不到就返回 {}（这时「全部货物」规则只对仓库有上限的货物生效）
function FIELDS.lineCargos(line)
	local set, list = {}, {}
	for i = 1, #line.stops do
		local cfg = line.stops[i].stopConfig
		local load = cfg and cfg.load
		if type(load) == "table" then
			for cargo, on in pairs(load) do
				if on and not set[cargo] then set[cargo] = true; list[#list + 1] = cargo end
			end
		end
	end
	return list
end

-- [待验证] Mat4f 的平移分量。TPF2 里 transf 是 16 个数的数组，平移在 13/14。
function FIELDS.translation(transf)
	if transf == nil then return nil end
	local x, y = transf[13], transf[14]
	if type(x) == "number" then return x, y end
	return nil
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

-- 仓库里现在有哪些货 { [货物] = 数量 }
function adapter.stockAll(warehouse)
	local ok, sl = pcall(api.engine.getComponent, tonumber(warehouse) or warehouse, ct().STOCK_LIST)
	if not ok or sl == nil then return {} end
	local ok2, all = pcall(FIELDS.stocks, sl)
	return ok2 and all or {}
end

function adapter.stock(warehouse, cargo)
	return adapter.stockAll(warehouse)[cargo] or 0
end

function adapter.lineCargos(line)
	local ok, list = pcall(FIELDS.lineCargos, line)
	return ok and list or {}
end

-- 实体所在的建筑（车站 / 仓库）。
-- [已知] CONSTRUCTION 组件有 transf；[待验证] STATION_GROUP.stations 和
-- streetConnectorSystem.getConstructionEntityForStation（TPF2 的名字）
local function constructionOf(entity)
	local ok, c = pcall(api.engine.getComponent, entity, ct().CONSTRUCTION)
	if ok and c then return c end
	local ok2, sg = pcall(api.engine.getComponent, entity, ct().STATION_GROUP)
	if ok2 and sg and sg.stations and sg.stations[1] then
		local ok3, con = pcall(api.engine.system.streetConnectorSystem.getConstructionEntityForStation, sg.stations[1])
		if ok3 and con and con >= 0 then
			local ok4, c2 = pcall(api.engine.getComponent, con, ct().CONSTRUCTION)
			if ok4 then return c2 end
		end
	end
	return nil
end

function adapter.position(entity)
	local c = constructionOf(entity)
	if c == nil then return nil end
	local ok, x, y = pcall(FIELDS.translation, c.transf)
	if ok then return x, y end
	return nil
end

-- 所有货物类型 { { id = "COAL", name = "煤" }, ... }。
-- [待验证] api.res.cargoTypeRep（TPF2 的名字）
function adapter.cargoTypes()
	local out = {}
	pcall(function()
		local rep = api.res.cargoTypeRep
		for id, v in pairs(rep.getAll()) do
			local cid = type(v) == "string" and v or id
			out[#out + 1] = { id = cid, name = adapter.cargoName(cid) }
		end
	end)
	table.sort(out, function(a, b) return a.name < b.name end)
	return out
end

function adapter.cargoName(cargo)
	local name
	pcall(function()
		local rep = api.res.cargoTypeRep
		local t = rep.get(rep.find(cargo))
		name = t and (t.name or t.shortName)
	end)
	if type(name) ~= "string" or name == "" then return tostring(cargo) end
	local ok, translated = pcall(_, name)
	return (ok and translated) or name
end

function adapter.entityName(entity)
	local ok, n = pcall(api.engine.getComponent, tonumber(entity) or entity, ct().NAME)
	return (ok and n and n.name) or tostring(entity)
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
