# SpeccyWall для Karabas Go / Mini / Mini G

Шестнадцать Pentagon 128 на одной ПЛИС (Xilinx Spartan-6 XC6SLX25), все на одном экране сеткой 4×4 и
выбранный на весь экран. Продолжение идеи [QuadSpeccy](https://github.com/Caasper911/karabas-go-core-quadspeccy)
(четыре машины), но машина уже не отдельный модуль: один процессор и одна шинная логика обслуживают по очереди
восемь машин, состояние каждой лежит в своей ячейке памяти (контекст).

**Состояние: начало работы.** Готов процессор на восемь машин (`tv80_oct`), проверен на эквивалентность
с восемью обычными tv80 и на тайминг отдельно от ядра. Ядра для платы пока нет. План в [docs/PLAN.md](docs/PLAN.md),
устройство в [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Что задумано

- 16 машин Pentagon 128 (128 КБ, без 1024 КБ Profi), общий ROM 128 / 48 в блочной памяти.
- Экран 4×4: у каждой машины paper 128×96 (каждый второй пиксель и строка) с бордюром в 1 пиксель; выбранная
  машина на весь экран, как в QuadSpeccy.
- Клавиатура и звук (beeper, один AY) — у выбранной машины. Без DivMMC / SD-карт и без мыши.
- Память: 12 машин в SRAM (4 МБ, есть на всех трёх платах), 4 в SDRAM (по банку на машину, контроллер QuadSpeccy).

## Структура

- `src/rtl/tv80/`: процессор tv80 (из karabas_go_v6z80p через QuadSpeccy) и `tv80_oct.v` — один tv80 на восемь
  CPU; `tv80o_core.v` / `tv80o_reg.v` генерирует `tools/mkctx.py` из `tv80_core.v` (не править руками).
- `src/sim/run_tv80o.sh`: тест `tv80_oct` против восьми `tv80_core` такт в такт (ISim из ISE 14.7).
- `src/test/run_timing.sh`: синтез и разводка одного `tv80_oct` на XC6SLX25, минимальный период и ресурсы.
- `modules/`: общие модули Karabas Go (сабмодуль karabas-go-modules).

```sh
git clone --recursive <repo>      # или git submodule update --init
src/sim/run_tv80o.sh              # эквивалентность, 2 млн тактов (SEED=<n> — другой случайный поток)
src/test/run_timing.sh            # тайминг tv80_oct
```

Лицензия: [LICENSE](LICENSE).
