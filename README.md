# QuadSpeccyX4 для Karabas Go / Mini / Mini G

Шестнадцать Pentagon 128 на одной ПЛИС (Xilinx Spartan-6 XC6SLX25), все на одном экране сеткой 4×4 и
выбранный на весь экран. Продолжение идеи [QuadSpeccy](https://github.com/Caasper911/karabas-go-core-quadspeccy)
(четыре машины), но машина уже не отдельный модуль: один процессор и одна шинная логика обслуживают по очереди
восемь машин, состояние каждой лежит в своей ячейке памяти (контекст); таких движков два.

**Состояние: 16 машин работают на Karabas Go, Mini, Mini G.** Ядро `src/quadspeccyx4.kg` — Go, Mini, Mini G (HDMI),
работает на всех трёх. План в [docs/PLAN.md](docs/PLAN.md), устройство в [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Как пользоваться

- На экране стена: 16 машин сеткой 4×4 на весь экран 1280×800 (48,88 Гц, кадр привязан к кадру Pentagon), paper
  каждой 1:1, вокруг её бордюр (32 точки по бокам, 4 строки сверху и снизу), выбранная — в рамке (цвет в OSD).
  Menu+B (OSD Wall border Show / Hide) — стена без бордюра: 16 paper вплотную, цельное поле 1024×768 в середине
  экрана (вокруг чёрное), рамка выбранной — по краю её paper. Полный экран от этого не меняется.
- Win+1..8 — машины 1..8, Shift+Win+1..8 — машины 9..16, Win+стрелки — соседняя; у выбранной клавиатура, Kempston,
  звук (beeper и один AY).
- Порт `#5A73` (только чтение, декодируются все 16 бит адреса): номер машины 0..15 (машина 1 на экране — 0); без этого
  порта Pentagon даёт FF. Пример: `LD BC,#5A73 : IN A,(C)` или `LD A,#5A : IN A,(#73)`.
- Win+` — выбранная машина на весь экран (×3 на весь 1280×800, поля — цвет бордюра; эффекты бордюра и мультиколор
  точные) и обратно.
- OSD (по порядку): Video 1280×800 (по умолчанию) / 720×576 (только полный экран; Menu+V — если монитор не покажет
  1280×800), Keys to (клавиатура и джойстик выбранной или всем — в стене), DivMMC, SD image, Frame fade (рамка гаснет
  через 2 с после выбора машины), Frame colour (цвет рамки выбранной в стене), Wall border (Menu+B: стена с бордюром /
  без); AY ABC / ACB, Tape in (Board — вход ленты платы слышат все машины; Core — все, кроме машины Tape out, слышат её
  MIC: SAVE на ней — LOAD на остальных), Tape out (машина на выходе ленты: Core 1..16), джойстики L и R; NMI All (Menu+F11, все 16 машин), NMI (F11, выбранная),
  Z80 Reset All (Menu+F12), Z80 Reset (F12, выбранная машина) — сбрасывают только процессоры, картинка не прерывается.
- DivMMC с ESXDOS 0.8.9 у каждой машины (OSD DivMMC On / Off; 128 КБ ОЗУ, у 16-й — 64 КБ: на ней `.browse` не запускается); SD-карта у всех одна —
  образ (OSD SD image: `.img` / `.mmc` / `.hdf` / `.vhd` / `.bin` из `/zx`), чтение и запись. NMI (F11) — меню ESXDOS; Win+F11 — NMI
  всем 16 машинам сразу.
- `.rndsna <папка>` (`software/launcher/RNDSNA` — в `/BIN` образа): запускает случайный `*.SNA` из папки
  через `.snapload` ESXDOS (48K и 128K). Случайность — от FRAMES и R: машины, запущенные в одном кадре одинаково
  (Reset All + autoexec), выберут один и тот же файл.
- `.rndtap <папка>` (`software/launcher/RNDTAP`): то же для `*.TAP`: вставляет ленту (`.tapein`) и выполняет
  `LOAD ""` в 48 BASIC (из 128 BASIC переключает ПЗУ, если пейджинг не заблокирован).
- `.rndtrd <папка>` (`software/launcher/RNDTRD`): то же для `*.TRD`: подключает образ диском A эмулятора TR-DOS
  ESXDOS (`.vdisk 0`) и выполняет `RANDOMIZE USR 15619: REM : RUN` (запуск `boot`); программа BASIC при этом
  заменяется. Нужны файлы SYS из дистрибутива ESXDOS 0.8.9 (с другими машина циклически перезапускается при старте).
- Готовый образ SD с демо (`software/img/build.sh` → `software/img/demotrd.img`, 512 МБ FAT32, в git не входит):
  ESXDOS 0.8.9 (`SYS`, `BIN`, `TMP` из дистрибутива `esxdos089.zip`, плюс `RNDSNA` / `RNDTAP` / `RNDTRD`), автозапуск
  (`AutoBoot=1` в `/SYS/CONFIG/ESXDOS.CFG`, `/SYS/AUTOBOOT.BAS`: `10 .rndtrd /DEMOTRD`), в `/DEMOTRD` — 522 TRD
  (длинные имена + короткие `0001.TRD`). Размер и имя: `MB=100 OUT=software/img/demotrd100.img` (кластер FAT32
  меньше 4 КБ у образов меньше 260 МБ).
  После старта или Reset All каждая машина запускает случайное демо.

## Устройство в двух словах

- Память: всё в SRAM платы (4 МБ, есть на всех трёх платах): RAM 16 машин, их ОЗУ DivMMC, ROM 128 / 48 / ESXDOS;
  очередь на два движка. Карты SD — в контекстах движков, один образ с кэшем 32 сектора. Без мыши, 1024 КБ Profi.
- Ресурсы: 61 % слайсов на Go, 73 % на Mini / Mini G, тайминг с запасом (`clk_bus` 24–29 нс из 35,7).

## Структура

- `src/rtl/tv80/`: процессор tv80 (из karabas_go_v6z80p через QuadSpeccy) и `tv80_oct.v` — один tv80 на восемь
  CPU; `tv80o_core.v` / `tv80o_reg.v` генерирует `tools/mkctx.py` из `tv80_core.v` (не править руками).
- `src/rtl/zx/zx_oct.v`: восемь Pentagon 128 на одном CPU и одной шинной логике (движок).
- `src/rtl/mem/`: `sram_ctrl.v` (SRAM), `sram_arb.v` (очередь двух движков), `sram_test.v` (самотест).
- `src/rtl/sd/`: `sd_oct.v` (SD-карты восьми машин движка), `sd_host.v` (16 карт на образ MCU, кэш секторов).
- `src/rtl/video/`: `wall_fetch.v` (строки стены), `zx_scr.v` (экран выбранной), `vga_out.v` (VGA на пиксельном
  клоке 73,6 МГц).
- `src/rtl/quadspeccyx4.v`, `karabas_go_top.v`: ядро и плата; `src/rtl/hid/`, `src/rtl/sound/`: клавиатура и AY из
  QuadSpeccy.
- `src/Makefile`, `karabas_go.{prj,xst,ucf,ut}`, `core.json`: сборка (`cd src && make go`, нужен
  `../karabas-go-tools` рядом).
- Тесты (ISim из ISE 14.7) в `src/sim/`: `run_tv80o.sh` (CPU на 8 машин против 8 `tv80_core`), `run_wall.sh`
  (движок против 8 эталонных машин, второй движок в ногу через очередь SRAM; `ROM=1` — ROM 128), `run_video.sh`
  (каждая точка VGA против памяти; `WALL=1` — стена, `MODE=0` — 720×576), `run_ps.sh` (движок после синтеза XST
  против RTL), `run_sd.sh` (16 машин грузят ESXDOS с образа), `run_core.sh` (всё ядро).
- `src/test/run_timing.sh [cpu8|wall8]`: пробная сборка на XC6SLX25.
- `software/launcher/`: dot-команды ESXDOS (`rndsna.asm`, `rndtap.asm`, `rndtrd.asm`, общая часть `rndsel.inc`; сборка `sjasmplus rndsna.asm` → `RNDSNA`, `sjasmplus rndtap.asm` → `RNDTAP`, `rndtrd.asm` → `RNDTRD`).
- `software/img/build.sh`: образ SD с демо (`tools/mkfat32.py` — образ FAT32 с длинными именами, `tools/mkbas.py` —
  BASIC-файл с заголовком +3DOS, как `SAVE *` ESXDOS).
- `modules/`: общие модули Karabas Go (сабмодуль karabas-go-modules).

```sh
git clone --recursive <repo>      # или git submodule update --init
src/sim/run_tv80o.sh              # эквивалентность CPU, 2 млн тактов (SEED=<n> — другой случайный поток)
src/sim/run_wall.sh               # движки против эталона; ROM=1 ./run_wall.sh 4587520 — 8 кадров ROM 128
src/sim/run_video.sh              # видео (WALL=1 — стена)
src/sim/run_ps.sh                 # движок после XST против RTL
cd src && make go                 # ядро для Go: quadspeccyx4.kg
```

Лицензия: [LICENSE](LICENSE).
