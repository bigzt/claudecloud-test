-- 游戏脚本：规则存在这里的状态里（随存档保存），每 2 秒跑一轮控制循环，
-- 并接收界面发来的修改事件。
function data()
	local M = "cargo_control::/scripts/cargo_control/"
	local shared = ug_require(M .. "shared.lua")
	local rules = ug_require(M .. "rules.lua")
	local controller = ug_require(M .. "controller.lua")
	local adapter = ug_require(M .. "adapter.lua")

	local INTERVAL = 2.0
	local timer = 0.0
	local started = false

	-- 第一次启动时把数据结构打到日志，用来核对 adapter.lua 的 FIELDS
	local function probe()
		pcall(function()
			local lines = adapter.lines()
			if lines[1] then adapter.dumpLine(lines[1]) end
		end)
		pcall(function()
			local ids = api.engine.getEntitiesWithComponent(api.type.ComponentType.STOCK_LIST)
			for i = 1, math.min(3, #ids) do adapter.dumpStock(ids[i]) end
		end)
	end

	local function onEvent(state, name, p)
		if type(p) ~= "table" then return end
		local s = rules.load(state:get())
		if name == shared.EV_STOP_RULE then
			local mode = p.mode ~= "" and p.mode or nil
			rules.setStopRule(s, p.line, p.stationGroup, p.cargo, mode)
		elseif name == shared.EV_CAP then
			local cap = (type(p.cap) == "number" and p.cap >= 0) and p.cap or nil
			rules.setWarehouseCap(s, p.warehouse, p.cargo, cap)
		elseif name == shared.EV_BIND then
			local wh = (type(p.warehouse) == "number" and p.warehouse >= 0) and p.warehouse or nil
			rules.bindStation(s, p.stationGroup, wh)
		else
			return
		end
		state:set(s)
		timer = INTERVAL -- 下一帧就生效
	end

	local function tick(state)
		local s = rules.load(state:get())
		local changes = controller.tick(s, adapter)
		for _, c in ipairs(changes) do
			shared.log(string.format("%s 第 %d 站 %s -> %s（%s）",
				adapter.entityName(c.line), c.stopIndex, tostring(c.cargo),
				c.unload and "卸" or "不卸", c.reason))
		end
		state:set(s)
	end

	return {
		update = function(_userParams, state, dt)
			if not started then
				started = true
				for _, ev in ipairs(shared.EVENTS) do state:subscribeToEvent(ev) end
				shared.log("游戏脚本已启动")
				probe()
			end
			if type(dt) ~= "number" or dt <= 0 then return nil end
			timer = timer + dt
			if timer < INTERVAL then return nil end
			timer = 0.0
			local ok, err = pcall(tick, state)
			if not ok then shared.log("本轮出错: " .. tostring(err)) end
			return nil
		end,

		handleEvent = function(_userParams, state, _src, id, name, param)
			if id ~= shared.EVENT_ID then return nil end
			local ok, err = pcall(onEvent, state, name, param)
			if not ok then shared.log("事件出错: " .. tostring(err)) end
			return nil
		end,
	}
end
