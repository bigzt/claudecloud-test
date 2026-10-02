-- 把 cargo_control.script.lua 挂到游戏底栏，使其每帧运行
function data()
	return {
		type = "react-plugin ::GameBarInfoDisplayExtension",
		data = {
			filePath = "cargo_control::/gui/cargo_control/cargo_control.script@CargoControlPlugin",
			priority = 5,
		}
	}
end
