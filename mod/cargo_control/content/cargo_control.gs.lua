-- 注册游戏脚本：控制循环和规则存储都在 cargo_control.script.lua
function data()
	return {
		updateScript = {
			fileName = "cargo_control.script@update",
		},
		handleEventScript = {
			fileName = "cargo_control.script@handleEvent",
		},
	}
end
