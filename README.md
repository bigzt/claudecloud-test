# Cargo Control（Transport Fever 3 mod）

精细控制物流链：

1. 仓库可设置禁止存放的货物（仓库窗口 →「货物存放限制」）
2. 线路可按站点、按货物设置卸 / 不卸（线路管理器 → 站点行 →「卸货」）
3. 仓库可按货物设置上限，超过则不卸货（上限 0 = 禁止存放）

设计、界面说明和第一次进游戏的验证步骤见 [docs/DESIGN.md](docs/DESIGN.md)。
mod 本体在 `mod/cargo_control/`。

测试：`lua5.2 tests/run.lua && lua5.2 tests/gui_smoke.lua`
