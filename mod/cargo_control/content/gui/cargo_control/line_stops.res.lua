-- 替换线路管理器每个站点行里的货物显示（LineCargoDisplay），在它后面加「卸货」设置
function data()
	return {
		type = "react-replacement-config",
		data = {
			filePath = "cargo_control::/gui/cargo_control/line_stops.script",
			doReplaceFn = "doReplace",
			order = 110,
		},
	}
end
