-- 需求 1 和 3：仓库窗口 → 「货物存放限制」按钮，展开后每种货物一行：
--   上限留空 = 不限；0 = 禁止存放；n = 最多存 n，满了停靠的车不卸这种货。
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

	-- [待验证] 仓库窗口脚本的路径和它导出的扩展点。按顺序试，第一个找到的生效。
	local CANDIDATES = {
		{ "::/gui/entity_window/warehouse/warehouse_eow.script.tl", "WarehouseEowExtensionPoint" },
		{ "::/gui/entity_window/storage/storage_eow.script.tl", "StorageEowExtensionPoint" },
		{ "::/gui/entity_window/construction/construction_eow.script.tl", "ConstructionEowExtensionPoint" },
	}

	local extensionPoint
	for _, c in ipairs(CANDIDATES) do
		local ok, mod = pcall(ug_require, c[1])
		if ok and type(mod) == "table" and mod[c[2]] ~= nil then
			extensionPoint = mod[c[2]]
			shared.log("仓库窗口扩展点: " .. c[1] .. " / " .. c[2])
			break
		end
	end
	if extensionPoint == nil then
		shared.log("找不到仓库窗口扩展点，仓库面板不显示。请把游戏目录 content/gui/entity_window/ 下的文件夹列表发给作者")
	end

	local ROW_BUTTONS = 4

	local function readWarehouse(wh)
		local st = shared.readState() or {}
		st.warehouses = st.warehouses or {}
		local caps = rules.warehouseCaps(st, wh)
		local stock = adapter.stockAll(wh)
		local listed, list = {}, {}
		local function add(c)
			if not listed[c] then listed[c] = true; list[#list + 1] = c end
		end
		for c in pairs(caps) do add(c) end
		for c in pairs(stock) do add(c) end
		table.sort(list)

		local rows = {}
		for _, c in ipairs(list) do
			rows[#rows + 1] = { cargo = c, name = adapter.cargoName(c), cap = caps[c], stock = stock[c] or 0 }
		end

		local others = {}
		for _, t in ipairs(adapter.cargoTypes()) do
			if not listed[t.id] then others[#others + 1] = t end
		end

		local stations = {}
		local links = st.status and st.status.links and st.status.links[rules.key(wh)]
		for _, sg in ipairs(links or {}) do stations[#stations + 1] = adapter.entityName(tonumber(sg) or sg) end

		return { rows = rows, others = others, stations = stations, hasRules = next(caps) ~= nil }
	end

	local function setCap(wh, cargo, cap)
		shared.send(shared.EV_CAP, { warehouse = wh, cargo = cargo, cap = cap or -1 })
	end

	local CapRow = react.RegisterRecipe("cargo_control_CapRow", function(params)
		local wh, row = params.warehouse, params.row
		local forbidden = row.cap == 0
		local capText = row.cap == nil and "" or tostring(row.cap)
		local stateText
		if row.cap == nil then stateText = "不限"
		elseif row.cap == 0 then stateText = "禁止存放"
		elseif row.stock >= row.cap then stateText = "已满，停卸"
		else stateText = "限量" end

		return builtin.BoxLayout{
			orientation = builtin.type.Orientation.Horizontal,
			children = {
				builtin.TextView{ meta = { class = "font-scale-body" }, text = row.name .. "  " .. row.stock },
				gui_react_util.makeHorizontalSpacer(),
				builtin.TextView{ meta = { class = "font-scale-annotation" }, text = "上限" },
				builtin.TextInputField{
					meta = { tooltip = "留空 = 不限；0 = 禁止存放", localKey = "cap" .. capText },
					value = capText,
					onValueChange = function(v)
						v = (v or ""):gsub("%s", "")
						if v == "" then setCap(wh, row.cargo, nil); return end
						local n = tonumber(v)
						if n and n >= 0 then setCap(wh, row.cargo, math.floor(n)) end
					end,
					acceptOnFocusLoss = true,
					resetValueOnCancel = true,
				},
				button_react_util.makeTextButton(
					"primary",
					forbidden and "取消禁止" or "禁止",
					function() setCap(wh, row.cargo, forbidden and nil or 0) end,
					nil
				),
				builtin.TextView{ meta = { class = "font-scale-annotation" }, text = stateText },
			},
		}
	end)

	local WarehouseRules = react.RegisterRecipe("cargo_control_WarehouseRules", function(params)
		local wh = params.entityId
		local dataState = engine_react_util.useStepState(function() return readWarehouse(wh) end)
		local openState = react.useState(false)
		local addState = react.useState(false)
		local d = dataState:old()
		local open = openState:old()

		local children = {
			builtin.BoxLayout{
				orientation = builtin.type.Orientation.Horizontal,
				children = {
					button_react_util.makeTextButton(
						"primary",
						(open and "▾ " or "▸ ") .. "货物存放限制" .. ((d and d.hasRules) and " *" or ""),
						function() openState:set(not open) end,
						"按货物设置禁止存放 / 上限（Cargo Control）"
					),
					gui_react_util.makeHorizontalSpacer(),
				},
			},
		}
		if open and d then
			children[#children + 1] = builtin.TextView{
				meta = { class = "font-scale-annotation" },
				text = "上限留空 = 不限，0 = 禁止存放。库存达到上限后，停靠关联车站的车辆不卸这种货，降到上限的 90% 恢复。",
			}
			for _, row in ipairs(d.rows) do
				children[#children + 1] = CapRow{ warehouse = wh, row = row }
			end

			if #d.others > 0 then
				children[#children + 1] = button_react_util.makeTextButton(
					"primary",
					(addState:old() and "▾ " or "▸ ") .. "添加货物",
					function() addState:set(not addState:old()) end,
					nil
				)
				if addState:old() then
					local row = {}
					local function flush()
						if #row > 0 then
							children[#children + 1] = builtin.BoxLayout{ orientation = builtin.type.Orientation.Horizontal, children = row }
						end
						row = {}
					end
					for _, t in ipairs(d.others) do
						-- 新加的货物默认「禁止」，玩家再改成具体上限
						row[#row + 1] = button_react_util.makeTextButton("primary", t.name, function()
							setCap(wh, t.id, 0)
							addState:set(false)
						end, nil)
						if #row >= ROW_BUTTONS then flush() end
					end
					flush()
				end
			end

			local linkText
			if #d.stations > 0 then
				linkText = "关联车站：" .. table.concat(d.stations, "、")
			elseif d.hasRules then
				linkText = "关联车站：无（400 米内没找到车站，规则暂时不生效）"
			else
				linkText = "设置规则后，会自动关联 400 米内的车站"
			end
			children[#children + 1] = builtin.TextView{ meta = { class = "font-scale-annotation" }, text = linkText }
		end

		return builtin.BoxLayout{
			orientation = builtin.type.Orientation.Vertical,
			children = children,
		}
	end)

	local module = {}
	if extensionPoint ~= nil then
		module.WarehousePanelPlugin = react.RegisterPluginRecipe(extensionPoint, "cargo_control_WarehousePanel", function(params)
			local ok, result = pcall(function() return WarehouseRules{ entityId = params.entityId } end)
			if not ok then
				shared.log("仓库面板出错: " .. tostring(result))
				return nil
			end
			return builtin.BoxLayout{ child = result }
		end)
	end
	return module
end
