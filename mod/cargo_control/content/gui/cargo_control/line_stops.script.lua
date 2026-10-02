-- 需求 2：线路管理器 → 站点行 → 「卸货」按钮，展开后按货物设置 默认 / 卸 / 不卸。
--
-- 做法和已上架的 TF3 mod「Improved Destination Displays」一样：替换
-- ::/gui/line_vehicle_mgmt/line_react_util.tl 导出的 LineCargoDisplay。
-- 站点行调用它时会带 stopCargoDisplay = true 和 stopIndex（从 0 开始），
-- 线路列表里调用时不带，那种情况原样返回。
function data()
	local builtin = ug_require("::/gui/main/builtin.lua")
	local react = ug_require("::/gui/main/react.lua")
	local engine_react_util = ug_require("::/gui/main/engine_react_util.tl")
	local gui_react_util = ug_require("::/gui/main/gui_react_util.tl")
	local button_react_util = ug_require("::/gui/main/button_react_util.tl")

	local M = "cargo_control::/scripts/cargo_control/"
	local shared = ug_require(M .. "shared.lua")
	local rules = ug_require(M .. "rules.lua")
	local adapter = ug_require(M .. "adapter.lua")

	local MODES = {
		{ mode = "", label = "默认" },
		{ mode = rules.UNLOAD, label = "卸" },
		{ mode = rules.KEEP, label = "不卸" },
	}

	local function modeLabel(mode)
		if mode == rules.UNLOAD then return "卸" end
		if mode == rules.KEEP then return "不卸" end
		return "默认"
	end

	-- 这一站的数据：站点组、线路运的货物、规则和当前状态
	local function readStop(lineEntity, stopIndex0)
		local line = adapter.readLine(lineEntity)
		local stop = line and line.stops and line.stops[stopIndex0 + 1]
		if not stop then return nil end
		local sg = stop.stationGroup
		local st = shared.readState() or {}
		st.stopRules = st.stopRules or {}

		local cargos, seen = {}, {}
		local function add(c)
			if c ~= rules.ALL and not seen[c] then seen[c] = true; cargos[#cargos + 1] = c end
		end
		for _, c in ipairs(adapter.lineCargos(line)) do add(c) end
		local l = st.stopRules[rules.key(lineEntity)]
		local s = l and l[rules.key(sg)]
		if s then for c in pairs(s) do add(c) end end
		table.sort(cargos)

		local status = st.status and st.status.stops and st.status.stops[rules.key(lineEntity)]
		status = status and status[rules.key(sg)] or {}

		local rows = { { cargo = rules.ALL, name = "全部货物", mode = rules.getOwnStopRule(st, lineEntity, sg, rules.ALL) } }
		for _, c in ipairs(cargos) do
			rows[#rows + 1] = {
				cargo = c,
				name = adapter.cargoName(c),
				mode = rules.getOwnStopRule(st, lineEntity, sg, c),
				reason = status[c] and status[c].reason,
				allow = status[c] and status[c].allow,
			}
		end
		local anyRule = s ~= nil and next(s) ~= nil
		return { sg = sg, rows = rows, anyRule = anyRule }
	end

	local function setRule(lineEntity, sg, cargo, mode)
		shared.send(shared.EV_STOP_RULE, { line = lineEntity, stationGroup = sg, cargo = cargo, mode = mode })
	end

	local UnloadPanel = react.RegisterRecipe("cargo_control_UnloadPanel", function(params)
		local info = params.info
		local children = {}
		for _, row in ipairs(info.rows) do
			local cells = {
				builtin.TextView{ meta = { class = "font-scale-body" }, text = row.name },
				gui_react_util.makeHorizontalSpacer(),
			}
			for _, m in ipairs(MODES) do
				local selected = (row.mode or "") == m.mode
				cells[#cells + 1] = button_react_util.makeTextButton(
					"primary",
					(selected and "● " or "") .. m.label,
					function() setRule(params.lineEntity, info.sg, row.cargo, m.mode) end,
					row.cargo == rules.ALL and "对这一站所有货物生效；单独设置的货物优先" or nil
				)
			end
			children[#children + 1] = builtin.BoxLayout{
				orientation = builtin.type.Orientation.Horizontal,
				children = cells,
			}
			if row.reason and row.allow ~= nil then
				children[#children + 1] = builtin.TextView{
					meta = { class = "font-scale-annotation" },
					text = "    当前：" .. (row.allow and "卸" or "不卸") .. "（" .. row.reason .. "）",
				}
			end
		end
		if #info.rows == 1 then
			children[#children + 1] = builtin.TextView{
				meta = { class = "font-scale-annotation" },
				text = "没读到这条线路运的货物，只能按「全部货物」设置",
			}
		end
		return builtin.BoxLayout{
			orientation = builtin.type.Orientation.Vertical,
			children = children,
		}
	end)

	local origCargoDisplay = nil

	local CargoControlCargoDisplay = react.RegisterRecipe("cargo_control_CargoDisplay", function(params)
		local original = react.CallOriginalRecipe(origCargoDisplay, params)
		if not params.stopCargoDisplay or params.stopIndex == nil then
			return builtin.BoxLayout{ child = original }
		end

		local ok, result = pcall(function()
			local lineEntity, stopIndex0 = params.lineEntity, params.stopIndex
			local infoState = engine_react_util.useStepState(function()
				return readStop(lineEntity, stopIndex0)
			end)
			local openState = react.useState(false)
			local info = infoState:old()
			if not info then return builtin.BoxLayout{ child = original } end

			local open = openState:old()
			local summary = info.anyRule and "卸货*" or "卸货"
			local children = {
				builtin.BoxLayout{
					orientation = builtin.type.Orientation.Horizontal,
					children = {
						original,
						button_react_util.makeTextButton(
							"primary",
							(open and "▾ " or "▸ ") .. summary,
							function() openState:set(not open) end,
							"按货物设置这一站卸不卸（Cargo Control）"
						),
						gui_react_util.makeHorizontalSpacer(),
					},
				},
			}
			if open then
				children[#children + 1] = UnloadPanel{ lineEntity = lineEntity, info = info }
			end
			return builtin.BoxLayout{
				orientation = builtin.type.Orientation.Vertical,
				children = children,
			}
		end)
		if not ok then
			shared.log("站点行出错: " .. tostring(result))
			return builtin.BoxLayout{ child = original }
		end
		return result
	end)

	local function doReplace(replacementApi)
		local found, line_react_util = pcall(ug_require, "::/gui/line_vehicle_mgmt/line_react_util.tl")
		if not found or line_react_util == nil or line_react_util.LineCargoDisplay == nil then
			shared.log("找不到 LineCargoDisplay，线路管理器不加卸货设置")
			return
		end
		origCargoDisplay = line_react_util.LineCargoDisplay
		replacementApi.ReplaceRecipe(origCargoDisplay, CargoControlCargoDisplay)
		shared.log("线路管理器卸货设置已安装")
	end

	return { doReplace = doReplace }
end
