# Cargo Control —— Transport Fever 3 物流链精细控制 mod 设计

## 需求

| # | 需求 | 在哪设置 | 本 mod 的做法 |
|---|---|---|---|
| 1 | 仓库可手动设置**禁止存放**的货物 | 仓库窗口 →「货物存放限制」 | 该货物上限设为 `0`（「禁止」按钮） |
| 2 | 线路可在**某站卸 / 不卸**某货物 | 线路管理器 → 站点行 →「卸货」 | 每种货物选 默认 / 卸 / 不卸 |
| 3 | 仓库**限量**，超过就不卸，`0` 即禁止 | 仓库窗口 →「货物存放限制」 | 上限 `n`：库存 ≥ n 停卸，降到约 90% 恢复 |

需求 1 是需求 3 在上限为 0 时的特例，两者用同一个输入框。

## 界面

### 仓库窗口（需求 1、3）

在仓库窗口加一个「▸ 货物存放限制」按钮（有规则时显示 `*`），展开后：

```
▾ 货物存放限制 *
  上限留空 = 不限，0 = 禁止存放。库存达到上限后……
  煤      28   上限 [ 500 ]  [禁止]      限量
  化学品   0   上限 [ 0   ]  [取消禁止]  禁止存放
  ▸ 添加货物            ← 展开后列出所有货物，点一个即加入（默认禁止）
  关联车站：源和 直升机场、岛间 车站
```

- 上限输入框：留空 = 不限，`0` = 禁止，数字 = 上限。回车或点别处生效。
- 列表里自动包含仓库现有库存的货物。
- 「关联车站」是 mod 自动算出的：仓库 400 米内的车站。规则只作用于停靠这些车站的线路。

> 你提议的位置是「配置」按钮旁边。游戏给 mod 开放的是**窗口内容扩展点**，
> 插件只能加在窗口内容里，不能插进底部按钮栏。所以这里做成内容区的一个可折叠按钮，
> 实际位置在进游戏后确认。

### 线路管理器（需求 2）

每个站点行原来的货物框后面加一个「▸ 卸货」按钮（有规则时显示 `卸货*`），展开后：

```
1  源和 直升机场   [🧪]  ▾ 卸货*
     全部货物   [● 默认] [卸] [不卸]
     化学品     [默认] [卸] [● 不卸]
         当前：不卸（站点规则：不卸）
2  岛间 直升机场   [  ]  ▸ 卸货
```

- 「全部货物」对这一站所有货物生效；单独设置的货物优先。
- 「当前」一行显示 mod 这一刻的实际判断和原因，比如「不卸（仓库已满 500/500）」。
- 规则跟着**车站**走，不跟站序号：线路增删、调整停靠顺序后规则不会错位。
  同一条线路多次停靠同一车站时共用一条规则。

挂载方式和已上架的 TF3 mod「Improved Destination Displays」相同：替换游戏
导出的 `LineCargoDisplay`，也就是站点行里那个货物框。

## 判断逻辑

线路 L 停靠车站 S 时，货物 C 卸不卸：

| 顺序 | 条件 | 结果 |
|---|---|---|
| 1 | L 在 S 对 C 设为「不卸」 | 不卸 |
| 2 | S 关联的仓库对 C 上限 = 0 | 不卸（禁止存放） |
| 3 | 库存 ≥ 上限，或停卸后还没降到恢复线 | 不卸（已满） |
| 4 | L 在 S 对 C 设为「卸」 | 卸 |
| 5 | 其他 | 不干预，保持游戏原设置 |

「卸」仍受仓库上限约束，即「超过则不卸货」优先。

实现：游戏脚本每 2 秒读一次仓库库存，按上表算出每个站点每种货物该卸不卸，
和线路当前设置不同才用 `makeLineUpdateCmd` 改（每条线路最多一条命令）。
第一次改某个设置时记下游戏原值，规则删除或库存回落后改回原值。

## 文件

```
mod/cargo_control/
  mod.json, _content.json, _metadata/modinfo.json   TF3 mod 格式
  content/cargo_control.gs.lua                       注册游戏脚本
  content/cargo_control.script.lua                   游戏脚本：规则存档、每 2 秒控制、接收界面事件
  content/gui/cargo_control/line_stops.*             线路管理器站点行的「卸货」设置
  content/gui/cargo_control/warehouse_panel.*        仓库窗口的「货物存放限制」
  content/scripts/cargo_control/rules.lua            判断规则（纯 Lua）
  content/scripts/cargo_control/controller.lua       控制循环、自动关联车站和仓库
  content/scripts/cargo_control/adapter.lua          唯一读写游戏数据的地方
  content/scripts/cargo_control/shared.lua           界面 ↔ 游戏脚本的事件和状态读取
tests/run.lua                                        规则和控制循环单测
tests/gui_smoke.lua                                  界面和游戏脚本冒烟测试（用桩代替游戏）
```

运行测试（仓库根目录，TF3 用的也是 Lua 5.2）：

```
lua5.2 tests/run.lua && lua5.2 tests/gui_smoke.lua
```

数据流：界面不直接改规则，而是用 `makeScriptingSendEventCmd` 发事件给游戏脚本；
游戏脚本改规则、存进自己的状态（随存档保存），并把「当前判断」写进状态给界面读。
这和 Improved Destination Displays 的做法一致，联机时各端也保持一致。

## API 依据与可信度

| 用到的东西 | 来源 | 可信度 |
|---|---|---|
| mod 格式、`ug_require`、`.gs.lua` 游戏脚本（`update` / `handleEvent` / `state:get/set/subscribeToEvent`） | 已上架 mod 的源码 | 已知 |
| `react.RegisterRecipe / RegisterPluginRecipe / CallOriginalRecipe / useState`、`engine_react_util.useStepState`、`builtin.BoxLayout / TextView / TextInputField`、`button_react_util.makeTextButton` | 已上架 mod 的源码 | 已知 |
| `react-replacement-config` 替换 `line_react_util.LineCargoDisplay`（参数 `lineEntity / stopIndex / stopCargoDisplay`） | Improved Destination Displays 源码 | 已知 |
| `makeScriptingSendEventCmd`、`makeLineUpdateCmd`、`gameScriptSystem.getEntityForGameScript` | 官方脚本文档、已上架 mod | 已知 |
| **仓库窗口扩展点**（猜的 `WarehouseEowExtensionPoint`） | 按 `LineEowExtensionPoint` / `IndustryEowExtensionPoint` 的命名规律推测 | **待验证** |
| 站点卸货设置在 `Stop.stopConfig` 里的具体字段 | 字段名已知，布局推测 | **待验证** |
| `STOCK_LIST` 里的货物类型和数量字段 | 由 `makeStockSetCargoAmountCmd` 参数推测 | **待验证** |
| `api.res.cargoTypeRep`、车站位置（`STATION_GROUP` → 建筑 `transf`） | TPF2 的名字 | **待验证** |

所有数据结构上待验证的部分都集中在 `adapter.lua` 的 `FIELDS` 表里。

## 第一次进游戏

1. 把 `mod/cargo_control` 复制到
   `<Steam>/userdata/<Steam ID>/3493540/local/staging_area/cargo_control`，
   在 Mod Hub 里启用。
2. 开一个存档，看游戏日志里 `[cargo_control]` 开头的行：
   - `游戏脚本已启动`
   - `线路管理器卸货设置已安装`
   - `仓库窗口扩展点: ...`，**或者** `找不到仓库窗口扩展点`
   - 紧接着是一条线路（`LINE ...`）和几个库存（`STOCK_LIST ...`）的完整结构
3. 把这些日志发给作者，用来修正 `FIELDS` 和仓库扩展点。
4. 如果出现「找不到仓库窗口扩展点」：在游戏安装目录里找
   `content/gui/entity_window/`，把里面的文件夹列表发过来，或者搜一下哪个文件包含
   `EowExtensionPoint` 且和仓库有关。

## 已知风险

- **货已在车上**：TF3 的货物出发时就规划了去处。仓库满了停卸后，车上的货可能被拉回
  或滞留。建议这些站点设短一点的最长等待时间。需要进游戏观察。
- **路由延迟**：改线路设置后，游戏重新规划货物路线需要时间，库存变化有滞后。
- **和其他 mod 共存**：Improved Destination Displays 也替换 `LineCargoDisplay`。
  替换是链式的（`CallOriginalRecipe`），理论上两个都能显示，需要实测。

## 后续

- 线路信息窗口（`LineEowExtensionPoint`）里也加一份分站卸货设置。
- 仓库面板里手动指定关联车站（规则层已支持 `CC_Bind` 事件，界面还没做）。
- 关联半径做成 mod 选项。
