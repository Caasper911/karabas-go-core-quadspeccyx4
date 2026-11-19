#!/bin/sh
# build.sh: software/img/demotrd.img, an SD card image of 512 MB (FAT32) for QuadSpeccyX4: ESXDOS 0.8.9 (SYS, BIN,
# TMP of the distribution esxdos089.zip: they must match the ROM of the core, src/roms/esxdos089.bin = its
# ESXMMC.BIN), the dot commands of software/launcher in /BIN, autoboot on (AutoBoot=1 in its /SYS/CONFIG/ESXDOS.CFG,
# /SYS/AUTOBOOT.BAS: 10 .rndtrd /DEMOTRD) and the demos of ../karabas-go-core-quadspeccy/DEMOTRD in /DEMOTRD.
# Env: ESXZIP, DEMODIR, MB, OUT (the image, demotrd.img by default), PYTHON, KEEP=1 (keep the staging directory work/).
set -e
here=$(cd "$(dirname "$0")" && pwd)
top=$here/../..
ESXZIP=${ESXZIP:-$top/../karabas_ex/firmware/src/fpga/profi/rom/esxdos089.zip}
DEMODIR=${DEMODIR:-$top/../karabas-go-core-quadspeccy/DEMOTRD}
MB=${MB:-512}
PYTHON=${PYTHON:-python}
OUT=${OUT:-$here/demotrd.img}
st=$here/work
rm -rf "${here:?}/work"
mkdir -p "$st/DEMOTRD"
"$PYTHON" - "$ESXZIP" "$st" <<'EOF'
import sys, zipfile
z = zipfile.ZipFile(sys.argv[1])
for n in z.namelist():
    if n.split('/')[0] in ('SYS', 'BIN', 'TMP'):
        z.extract(n, sys.argv[2])
EOF
cfg=$st/SYS/CONFIG/ESXDOS.CFG
grep -q '^AutoBoot=' "$cfg"
sed -i 's/^AutoBoot=.*/AutoBoot=1/' "$cfg"
"$PYTHON" -c "import sys, zipfile
if zipfile.ZipFile(sys.argv[1]).read('ESXMMC.BIN') != open(sys.argv[2], 'rb').read():
    sys.stderr.write('warning: ESXMMC.BIN of the zip is not src/roms/esxdos089.bin\n')" "$ESXZIP" "$top/src/roms/esxdos089.bin"
cp -p "$top"/software/launcher/RNDSNA "$top"/software/launcher/RNDTAP "$top"/software/launcher/RNDTRD "$st/BIN/"
"$PYTHON" "$top/tools/mkbas.py" "$st/SYS/AUTOBOOT.BAS" 10 ".rndtrd /DEMOTRD"
cp -p "$DEMODIR"/* "$st/DEMOTRD/"
"$PYTHON" "$top/tools/mkfat32.py" "$st" "$OUT" "$MB"
[ -n "$KEEP" ] || rm -rf "${here:?}/work"
