# SpeccyWall для Karabas Go / Mini / Mini G

Шестнадцать Pentagon 128 на одной ПЛИС (Xilinx Spartan-6 XC6SLX25), все на одном экране сеткой 4×4 и
выбранный на весь экран. Продолжение идеи [QuadSpeccy](https://github.com/Caasper911/karabas-go-core-quadspeccy)
(четыре машины), но машина уже не отдельный модуль: один процессор и одна шинная логика обслуживают по очереди
восемь машин, состояние каждой лежит в своей ячейке памяти (контекст); таких движков два.

**Состояние: 16 машин работают на Karabas Go, Mini, Mini G.** Ядро `src/speccywall.kg` — Go, Mini, Mini G (HDMI),
работает на всех трёх. План в [docs/PLAN.md](docs/PLAN.md), устройство в [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Как пользоваться

- На экране стена: 16 машин сеткой 4×4 на весь экран 1280×800 (48,88 Гц, кадр привязан к кадру Pentagon), paper
  каждой 1:1, вокруг её бордюр (32 точки по бокам, 4 строки сверху и снизу), выбранная — в рамке (цвет в OSD).
- Win+1..8 — машины 1..8, Shift+Win+1..8 — машины 9..16, Win+стрелки — соседняя; у выбранной клавиатура, Kempston,
  звук (beeper и один AY).
- Win+` — выбранная машина на весь экран (×3 на весь 1280×800, поля — цвет бордюра; эффекты бордюра и мультиколор
  точные) и обратно.
- OSD: Video 1280×800 (по умолчанию) / 720×576 (только полный экран; Menu+V — если монитор не покажет 1280×800),
  джойстики, AY ABC / ACB, Frame colour (цвет рамки выбранной в стене), Frame fade (рамка гаснет через
  2 с после выбора машины), Tape in (Board — вход ленты платы слышат все машины; Core — все, кроме машины Tape out, слышат её MIC:
  SAVE на ней — LOAD на остальных), Tape out (машина на выходе ленты: Core 1..16), Keys to (клавиатура и
  джойстик выбранной или всем — в стене), NMI (F11), Reset выбранной (F12), Reset All (Menu+F12).
- При старте и по Reset All ядро ~0,2 с проверяет SRAM.

## Устройство в двух словах

- Память: все 16 машин в SRAM платы (2 МБ из 4, есть на всех трёх платах), очередь на два движка; ROM 128 / 48 в
  блочной памяти. Без DivMMC / SD-карт, мыши, 1024 КБ Profi.
- Ресурсы: 50 % слайсов, тайминг с запасом (`clk_bus` 24 нс из 35,7).

## Структура

- `src/rtl/tv80/`: процессор tv80 (из karabas_go_v6z80p через QuadSpeccy) и `tv80_oct.v` — один tv80 на восемь
  CPU; `tv80o_core.v` / `tv80o_reg.v` генерирует `tools/mkctx.py` из `tv80_core.v` (не править руками).
- `src/rtl/zx/zx_oct.v`: восемь Pentagon 128 на одном CPU и одной шинной логике (движок).
- `src/rtl/mem/`: `sram_ctrl.v` (SRAM), `sram_arb.v` (очередь двух движков), `sram_test.v` (самотест).
- `src/rtl/video/`: `wall_fetch.v` (строки стены), `zx_scr.v` (экран выбранной), `vga_out.v` (VGA на пиксельном
  клоке 73,6 МГц).
- `src/rtl/speccywall.v`, `karabas_go_top.v`: ядро и плата; `src/rtl/hid/`, `src/rtl/sound/`: клавиатура и AY из
  QuadSpeccy.
- `src/Makefile`, `karabas_go.{prj,xst,ucf,ut}`, `core.json`: сборка (`cd src && make go`, нужен
  `../karabas-go-tools` рядом).
- Тесты (ISim из ISE 14.7) в `src/sim/`: `run_tv80o.sh` (CPU на 8 машин против 8 `tv80_core`), `run_wall.sh`
  (движок против 8 эталонных машин, второй движок в ногу через очередь SRAM; `ROM=1` — ROM 128), `run_video.sh`
  (каждая точка VGA против памяти; `WALL=1` — стена, `MODE=0` — 720×576), `run_ps.sh` (движок после синтеза XST
  против RTL), `run_core.sh` (всё ядро).
- `src/test/run_timing.sh [cpu8|wall8]`: пробная сборка на XC6SLX25.
- `modules/`: общие модули Karabas Go (сабмодуль karabas-go-modules).

```sh
git clone --recursive <repo>      # или git submodule update --init
src/sim/run_tv80o.sh              # эквивалентность CPU, 2 млн тактов (SEED=<n> — другой случайный поток)
src/sim/run_wall.sh               # движки против эталона; ROM=1 ./run_wall.sh 4587520 — 8 кадров ROM 128
src/sim/run_video.sh              # видео (WALL=1 — стена)
src/sim/run_ps.sh                 # движок после XST против RTL
cd src && make go                 # ядро для Go: speccywall.kg
```

Лицензия: [LICENSE](LICENSE).
