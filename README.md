# Cargo Control（Transport Fever 3 mod）

精细控制物流链：

1. 仓库可设置禁止存放的货物
2. 线路可按站点、按货物设置卸 / 不卸
3. 仓库可按货物设置上限，超过则不卸货（上限 0 = 禁止存放）

设计、用法和进游戏后的验证步骤见 [docs/DESIGN.md](docs/DESIGN.md)。
mod 本体在 `mod/cargo_control/`，测试：`lua5.2 tests/run.lua`。
