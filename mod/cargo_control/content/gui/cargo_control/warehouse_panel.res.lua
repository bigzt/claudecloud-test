-- 仓库窗口里加「货物存放限制」面板。
-- [待验证] 扩展点名字是按已知的 LineEowExtensionPoint / IndustryEowExtensionPoint
-- 命名规律猜的；如果日志里出现「找不到仓库窗口扩展点」，改这里和
-- warehouse_panel.script.lua 里的 CANDIDATES。
function data()
	return {
		type = "react-plugin ::WarehouseEowExtensionPoint",
		data = {
			filePath = "cargo_control::/gui/cargo_control/warehouse_panel.script@WarehousePanelPlugin",
			order = 90,
		},
	}
end
