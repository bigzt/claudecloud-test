-- 界面和游戏脚本共用的常量，以及界面侧读状态、发事件的工具。
local shared = {}

shared.MOD_ID = "cargo_control"
shared.TAG = "[cargo_control] "
shared.GAME_SCRIPT = "cargo_control::/cargo_control.gs"
shared.EVENT_ID = "CargoControl"

-- 事件名 -> 参数
shared.EV_STOP_RULE = "CC_SetStopRule" -- { line, stationGroup, cargo, mode = "unload"|"keep"|"" }
shared.EV_CAP = "CC_SetCap"            -- { warehouse, cargo, cap = 数字，-1 表示取消 }
shared.EV_BIND = "CC_Bind"             -- { stationGroup, warehouse = 实体，-1 表示取消 }
shared.EVENTS = { shared.EV_STOP_RULE, shared.EV_CAP, shared.EV_BIND }

function shared.log(line)
	pcall(debugPrint, shared.TAG .. line)
end

-- 界面侧：发事件给游戏脚本
function shared.send(name, param)
	api.cmd.sendCommand(api.cmd.makeScriptingSendEventCmd("", shared.EVENT_ID, name, param))
end

-- 界面侧：读游戏脚本的状态（每帧最多读一次）
local cachedTick, cachedState = nil, nil
function shared.readState()
	local tick
	pcall(function()
		local gt = api.engine.getComponent(api.engine.util.getWorld(), api.type.ComponentType.GAME_TIME)
		tick = gt and gt.tickCount
	end)
	if tick ~= nil and tick == cachedTick then return cachedState end
	cachedTick = tick
	cachedState = nil
	pcall(function()
		local e = api.engine.system.gameScriptSystem.getEntityForGameScript(shared.GAME_SCRIPT)
		if e and e >= 0 then
			local gs = api.engine.getComponent(e, api.type.ComponentType.GAME_SCRIPT)
			cachedState = gs and gs.state
		end
	end)
	return cachedState
end

return shared
