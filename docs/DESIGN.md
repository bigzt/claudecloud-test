# Cargo Control —— Transport Fever 3 物流链精细控制 mod 设计

## 需求

| # | 需求 | 本 mod 的做法 |
|---|---|---|
| 1 | 仓库可手动设置**禁止存放**的货物 | 仓库对该货物的上限设为 `0` |
| 2 | 线路可在**某站卸 / 不卸**某货物 | 站点规则 `unload`（此站卸）/ `keep`（此站不卸） |
| 3 | 仓库**限量**，超过就不卸，`0` 即禁止 | 仓库上限 `n`：库存 ≥ n 停卸，降到 `n - 回差` 再恢复 |

三条需求合起来就是一个判断：**线路 L 第 i 站到站时，货物 C 卸不卸？**
需求 1 是需求 3 在上限为 0 时的特例，所以两者用同一套逻辑。

## 核心思路

TF3 里车站本身不再存货，货只有在有去处（工厂、需求方或仓库）时才能卸下；
线路窗口里可以按货物设置每站的装 / 卸，并有“到站强制卸货”。

所以本 mod **不改仓库本身**，而是做一个控制循环：

```
每 60 帧：
  读各仓库每种货物的库存（STOCK_LIST）
  对每条线路的每个站点、每种有规则的货物：
      allow = rules.decide(...)      -- true 卸 / false 不卸 / nil 不干预
  如果和线路当前设置不同 → 改线路副本 → makeLineUpdateCmd 写回（每条线路最多一条命令）
```

这样“仓库禁存 / 限量”会作用到**所有停靠该仓库所在站点的线路**，
“站点规则”只作用到那条线路的那一站。

### 判断优先级（`rules.decide`）

| 顺序 | 条件 | 结果 |
|---|---|---|
| 1 | 站点规则 = `keep` | 不卸 |
| 2 | 站点绑定的仓库对此货物上限 = 0 | 不卸（禁止存放） |
| 3 | 库存 ≥ 上限，或在回差区内且上次是停卸 | 不卸（已满） |
| 4 | 站点规则 = `unload` | 卸 |
| 5 | 其他 | 不干预，沿用游戏/玩家原设置 |

强制卸货（4）**仍受仓库上限约束**（2、3），即“超过则不卸货”优先。

### 还原

mod 第一次改某个设置时，把游戏原值记在 `state.overrides`。规则删除或条件
解除（比如库存回落）时，把原值写回并删掉记录。删掉 mod 前先清空规则跑一轮，
线路就回到原状。

### 回差

上限 100、回差比例 0.1 时：库存到 100 停卸，降到 90 才恢复。避免库存在
99/100 之间来回跳，每帧都改线路。

## 文件

```
mod/cargo_control/
  mod.json, _content.json, _metadata/modinfo.json   TF3 mod 格式
  content/gui/cargo_control/cargo_control.res.lua    把插件挂到游戏底栏
  content/gui/cargo_control/cargo_control.script.lua 入口：启动、定时、存档、控制台命令
  content/scripts/cargo_control/rules.lua            规则引擎（纯 Lua，无游戏依赖）
  content/scripts/cargo_control/controller.lua       控制循环（通过 adapter 访问游戏）
  content/scripts/cargo_control/adapter.lua          唯一调用 api.* 的地方
tests/run.lua                                        游戏外单测
```

运行测试：在仓库根目录执行 `lua5.2 tests/run.lua`（TF3 用的就是 Lua 5.2）。

## 用法（第一版：控制台）

第一版还没有图形界面，规则在游戏控制台里设置（打开调试模式后可用控制台）：

```lua
cargoctl.bind(站点组ID, 仓库ID)          -- 这个站卸下的货进哪个仓库
cargoctl.forbid(仓库ID, "COAL")           -- 需求1：仓库禁存煤
cargoctl.cap(仓库ID, "IRON_ORE", 500)     -- 需求3：铁矿最多 500，满了不卸
cargoctl.cap(仓库ID, "IRON_ORE", nil)     -- 取消限制
cargoctl.stop(线路ID, 2, "PLANKS", "keep")   -- 需求2：此线第 2 站不卸木板
cargoctl.stop(线路ID, 3, "PLANKS", "unload") -- 此线第 3 站卸木板
cargoctl.stop(线路ID, 3, "PLANKS", nil)      -- 清除
cargoctl.hysteresis(0.1)                  -- 回差比例
cargoctl.show()                           -- 查看当前规则
```

货物 ID 用游戏内部名（如 `COAL`），实体 ID 可在调试模式下点选实体查看。

## API 依据与可信度

TF3 于 2026-09-29 发售，官方脚本文档在 `wiki.transportfever3.com/script-doc/`。
本次开发环境无法直接访问该站点，API 名字来自公开的 TF3 mod 项目对官方文档
的整理（[Transport-Fever-3-Multiplayer-Mod](https://github.com/Juliansgith/Transport-Fever-3-Multiplayer-Mod)
的 `investigation/` 目录）。

| 用到的东西 | 来源 | 可信度 |
|---|---|---|
| mod.json / _content.json / modinfo.json 格式，`ug_require`，react 插件 `GameBarInfoDisplayExtension` + `react.onStep` | 已上架 TF3 mod 的实际用法 | 已知 |
| `api.engine.getComponent`、`getEntitiesWithComponent`、`ComponentType.LINE / STOCK_LIST` | 已上架 mod 使用 | 已知 |
| `api.cmd.makeLineUpdateCmd(lineEntity, Engine.Component.Line)`、`sendCommand` | 官方脚本文档 | 已知 |
| `api.gui.game.getGuiSaveData / setGuiSaveData`（数据随存档） | 已上架 mod 使用 | 已知 |
| `Line.stops[i].stationGroup`、`Stop.loadMode`、`Stop.stopConfig`、`Line.customFilters` | 字段名已知 | **布局待验证** |
| `STOCK_LIST` 里每个 stock 的货物类型、数量字段 | 由 `makeStockSetCargoAmountCmd(entity, stockId, amount, cargoType)` 推测 | **待验证** |

**所有待验证的部分都集中在 `adapter.lua` 的 `FIELDS` 表里**，其他文件不依赖游戏
数据结构。

## 进游戏后的第一步：确认字段

1. 把 `mod/cargo_control` 复制到
   `<Steam>/userdata/<Steam ID>/3493540/local/staging_area/cargo_control`，
   在 Mod Hub 里启用。
2. 开一个存档，日志里应出现 `[cargo_control] 已加载`。
3. 在线路窗口里手动把某站某货物改成“不卸”，然后控制台执行
   `cargoctl.dumpLine(线路ID)`，对比改前改后日志，找到装卸设置实际存在哪个字段。
4. 对一个有货的仓库执行 `cargoctl.dumpStock(仓库ID)`，找到货物类型和数量字段。
5. 按结果改 `adapter.lua` 的 `FIELDS.getUnload / setUnload / stock`。

如果第 3 步发现每站装卸设置不在 `stopConfig` 而在 `Line.customFilters`，同样只改 `FIELDS`。

## 已知风险

- **货已在车上**：TF3 的货物在出发时就规划了去处。如果仓库已满、停止卸货，
  车上的这批货可能被带回或滞留在车上。建议这些站点配合设置较短的最长等待时间，
  或者给站点绑定第二个溢出仓库。进游戏后需要观察实际表现。
- **路由不会立刻变**：改线路设置后，游戏可能要重新计算货物路线，库存变化有延迟。
  回差就是为此设置的，必要时调大。
- **多人游戏**：控制循环跑在 GUI 状态里，单机没问题。多人联机要搬到游戏脚本
  （`update` / `handleEvent`），并通过 `makeScriptingSendEventCmd` 下发规则，
  以保证各端一致。

## 后续

1. 进游戏确认 `FIELDS`（上一节）。
2. 图形界面：在仓库窗口加“每种货物上限”一栏，在线路窗口的每站加“卸 / 不卸 / 默认”
   开关。已知的窗口扩展点有 `IndustryEowExtensionPoint`、`VehicleEowExtensionPoint`
   等；仓库和线路窗口的扩展点名字需要在游戏的 `.tl` 源文件里找。
3. 自动绑定站点和仓库（现在要手动 `bind`）。
4. “禁止存放”的第二种实现：仓库槽位专用化 `makeStockListSetStocksCargoTypeCmd`，
   直接不给该货物分配槽位。可以和本方案配合使用。
