"""mkctx.py tv80_core.v <out_dir> [N]

Makes the N-context tv80 core out of tv80_core (N = 8 by default: tv80o_core.v and tv80o_reg.v in <out_dir>): one
copy of the logic, the state of N CPUs, one clock per CPU. After tools/mkquad.py of karabas-go-quadspeccy (four
contexts, two clocks per CPU: its cen and a "peek" clock that shows the outputs); here the outputs come from a
second read port of the state instead, so a CPU needs one clock.

- Input th (log2 N bits) is the CPU of this clock: every register X of the clocked blocks becomes a memory
  X_m[0:N-1]; X (what the logic reads) is X_m[th]; each clocked block computes the next value of its registers in
  X_n (blocking, starting from X, the old value: what was a non-blocking X <= v is X_n = v, a part X[i] the same part
  of X_n) and writes X_m[th] <= X_n at its end. The right hand sides still read X, the old value, as the
  non-blocking assignments did, and the last assignment wins, as before. The asynchronous resets become synchronous
  (reset_n is the reset of CPU th). The combinational logic (mcode, ALU and the rest) is unchanged and shared.
- Input pth is a second CPU: the registers that make the outputs (PEEK below) have a second read X_p = X_m[pth], and
  the outputs of CPU pth are ports p_*: A, dout, m1_n, mc, ts, halt_n, intcycle_n straight from its registers, iorq,
  no_read, write from a second tv80_mcode on its IR / ISet / mcycle / F / NMICycle / IntCycle (XST keeps only the
  cone of those three outputs). The wrapper (tv80_oct.v) sets pth = th - 1: the outputs of the CPU of the last clock,
  which is how a tv80_core shows them (they change with the clock of its cen).
- tv80_reg becomes tv80o_reg (the register file of the N CPUs, written here too). It is not written while reset_n
  is low: tv80_core is in its asynchronous reset at once and writes nothing, the synchronous reset here sees the old
  state in that clock (tv80_quad of QuadSpeccy has this difference: a register can change at a reset there).

The equivalence test src/sim/tb_tv80o.v compares tv80_oct with eight tv80_core clock for clock.
"""
import re
import sys

src_path, out_dir = sys.argv[1], sys.argv[2]
N = int(sys.argv[3]) if len(sys.argv) > 3 else 8
TB = (N - 1).bit_length()
assert 1 << TB == N, 'N must be a power of two'
SUF = {8: 'o'}.get(N, f'x{N}')        # tv80o_core for 8, tv80x16_core for 16
CORE, REG = f'tv80{SUF}_core', f'tv80{SUF}_reg'

# the registers the outputs are made of: second read port (pth)
PEEK = ['A', 'dout', 'm1_n', 'mcycle', 'tstate', 'Halt_FF', 'IntCycle', 'IR', 'ISet', 'F', 'NMICycle']

src = open(src_path).read()


def strip_ifdef(text, name):
    """remove the `ifdef name parts (name not defined): keep the `else parts and every other `ifdef as it is"""
    out = []
    stack = []   # per open `ifdef / `ifndef: [is ours, the part now is kept]
    for line in text.split('\n'):
        s = line.strip()
        tok = s.split()
        if tok and tok[0] in ('`ifdef', '`ifndef'):
            ours = len(tok) > 1 and tok[1] == name
            stack.append([ours, (tok[0] == '`ifndef') if ours else True])
            if ours:
                continue
        elif tok and tok[0] == '`else' and stack:
            if stack[-1][0]:
                stack[-1][1] = not stack[-1][1]
                continue
        elif tok and tok[0] == '`endif' and stack:
            top = stack.pop()
            if top[0]:
                continue
        if all(keep for ours, keep in stack if ours):
            out.append(line)
    return '\n'.join(out)


# drop `ifdef TV80_REFRESH (not used: no DRAM refresh address), keep its `else part
src = strip_ifdef(src, 'TV80_REFRESH')
lines = src.split('\n')

# the clocked blocks
blocks = []
i = 0
while i < len(lines):
    if re.search(r'always\s*@\s*\(\s*posedge clk', lines[i]):
        depth, j, started = 0, i, False
        while True:
            l = re.sub(r'//.*', '', lines[j])
            nb = len(re.findall(r'\bbegin\b', l))
            depth += nb
            started = started or nb > 0
            depth -= len(re.findall(r'\bend\b', l))
            if started and depth == 0:
                break
            j += 1
        blocks.append((i, j))
        i = j
    i += 1

lhs_re = re.compile(r'^(\s*)([A-Za-z_][A-Za-z0-9_]*)(\[[^\]]*\])?\s*<=\s*(`TV80DELAY\s*)?')
assigned = {}
for (a, b) in blocks:
    names = []
    for k in range(a, b + 1):
        m = lhs_re.match(lines[k])
        if m and m.group(2) not in names:
            names.append(m.group(2))
    assigned[(a, b)] = names
all_names = [n for v in assigned.values() for n in v]
assert len(all_names) == len(set(all_names)), 'a register in two blocks'
missing = [n for n in PEEK if n not in all_names]
assert not missing, f'not a register of a clocked block: {missing}'

# rewrite the blocks (from the last, the line numbers stay valid)
for (a, b) in sorted(blocks, reverse=True):
    names = assigned[(a, b)]
    for k in range(a, b + 1):
        m = lhs_re.match(lines[k])
        if m:
            lines[k] = m.group(1) + m.group(2) + '_n' + (m.group(3) or '') + ' = ' + lines[k][m.end():]
    lines[a] = re.sub(r'always\s*@\s*\(\s*posedge clk[^)]*\)', 'always @ (posedge clk)', lines[a])
    # the first begin (on the always line or the next)
    k = a
    while not re.search(r'\bbegin\b', re.sub(r'//.*', '', lines[k])):
        k += 1
    ind = re.match(r'\s*', lines[k]).group(0) + '  '
    lines[k] = lines[k] + '\n' + '\n'.join(f'{ind}{n}_n = {n};' for n in names)
    # before the last end
    ind_e = re.match(r'\s*', lines[b]).group(0) + '  '
    lines[b] = '\n'.join(f'{ind_e}{n}_m[th] <= {n}_n;' for n in names) + '\n' + lines[b]

src = '\n'.join(lines)

# the declarations of the registers: reg [w] a, b;  ->  memories, next values, the reads of CPU th (and pth)
decl_re = re.compile(r'^(\s*)reg\s*(\[[^\]]*\])?\s*([A-Za-z0-9_,\s]+);(.*)$', re.M)


def decl(m):
    ind, width, names, rest = m.group(1), m.group(2) or '', [n.strip() for n in m.group(3).split(',')], m.group(4)
    keep = [n for n in names if n not in all_names]
    out = []
    if keep:
        out.append(f'{ind}reg {width} {", ".join(keep)};{rest}')
    for n in names:
        if n in all_names:
            out.append(f'{ind}reg {width} {n}_m [0:{N - 1}];')
            out.append(f'{ind}reg {width} {n}_n;')
            out.append(f'{ind}wire {width} {n} = {n}_m[th];')
            if n in PEEK:
                out.append(f'{ind}wire {width} {n}_p = {n}_m[pth];')
    return '\n'.join(out)


src = decl_re.sub(decl, src)
missing = [n for n in all_names if f'{n}_m [0:{N - 1}]' not in src]
assert not missing, missing
missing = [n for n in PEEK if f' {n}_p = ' not in src]
assert not missing, missing

# the module: name, ports th / pth and the outputs of CPU pth
P_OUT = [('[15:0]', 'p_A'), ('[7:0]', 'p_dout'), ('', 'p_m1_n'), ('[6:0]', 'p_mc'), ('[6:0]', 'p_ts'),
         ('', 'p_halt_n'), ('', 'p_intcycle_n'), ('', 'p_iorq'), ('', 'p_no_read'), ('', 'p_write')]
src = src.replace('module tv80_core (', f'module {CORE} (\n  th, pth, ' + ', '.join(n for w, n in P_OUT) + ',', 1)
decls = (f'  input [{TB - 1}:0] th;      // the CPU of this clock: its state is read and written\n'
         f'  input [{TB - 1}:0] pth;     // the CPU whose outputs are p_*\n' +
         ''.join(f'  output {w} {n};\n' for w, n in P_OUT))
assert '  input     clk;' in src
src = src.replace('  input     clk;', '  input     clk;\n' + decls, 1)
src = re.sub(r'tv80_reg\s+i_reg', f'{REG} i_reg', src)
# no register file write in a reset clock: tv80_core is in reset at once (asynchronous) and writes nothing, here the
# reset is synchronous and the logic still sees the state from before it (the register file has no reset, a write
# there would stay)
n_cen = len(re.findall(r'\.CEN\s*\(ClkEn\)', src))
assert n_cen == 1, n_cen
src = re.sub(r'\.CEN\s*\(ClkEn\)', '.CEN                  (ClkEn && reset_n)', src)
src = re.sub(rf'({REG} i_reg\s*\(\s*)', r'\1\n     .th                   (th),', src)

# the second mcode: the parameters of the first one
m = re.search(r'tv80_mcode\s*(#\s*\([^)]*\))\s*i_mcode', src)
assert m, 'tv80_mcode i_mcode not found'
peek = f'''
  // the outputs of CPU pth (tools/mkctx.py): its registers through the second read port, IORQ / NoRead / Write
  // from a second mcode (only the cone of these three outputs is kept)
  tv80_mcode {m.group(1)} p_mcode
    (
     .IR                   (IR_p),
     .ISet                 (ISet_p),
     .MCycle               (mcycle_p),
     .F                    (F_p),
     .NMICycle             (NMICycle_p),
     .IntCycle             (IntCycle_p),
     .IORQ                 (p_iorq),
     .NoRead               (p_no_read),
     .Write                (p_write)
     );
  assign p_A = A_p;
  assign p_dout = dout_p;
  assign p_m1_n = m1_n_p;
  assign p_mc = mcycle_p;
  assign p_ts = tstate_p;
  assign p_halt_n = ~ Halt_FF_p;
  assign p_intcycle_n = ~ IntCycle_p;

endmodule'''
k = src.rfind('endmodule')
src = src[:k] + peek.lstrip('\n') + src[k + len('endmodule'):]

head = (f'// GENERATED by tools/mkctx.py from tv80_core.v: do not edit, edit the generator or tv80_core.v.\n'
        f'// The {N}-context tv80 core: see tools/mkctx.py.\n')
open(f'{out_dir}/{CORE}.v', 'w', newline='\n').write(head + src)

E = N * 8
reg = f'''// GENERATED by tools/mkctx.py: do not edit.
// {REG}: the register file of tv80_reg (BC, DE, HL, IX, IY and their alternates) for {N} CPUs: CPU th uses the
// entries {{th, n}}. One write port (A), three read ports (A, B, C) as tv80_reg, {E} entries instead of 8.
module {REG} (
  input  [{TB - 1}:0] th,
  input        clk,
  input        CEN,
  input        WEH,
  input        WEL,
  input  [2:0] AddrA,
  input  [2:0] AddrB,
  input  [2:0] AddrC,
  input  [7:0] DIH,
  input  [7:0] DIL,
  output [7:0] DOAH,
  output [7:0] DOAL,
  output [7:0] DOBH,
  output [7:0] DOBL,
  output [7:0] DOCH,
  output [7:0] DOCL
  );

  reg [7:0] RegsH [0:{E - 1}];
  reg [7:0] RegsL [0:{E - 1}];

  always @(posedge clk)
    if (CEN) begin
      if (WEH) RegsH[{{th, AddrA}}] <= DIH;
      if (WEL) RegsL[{{th, AddrA}}] <= DIL;
    end

  assign DOAH = RegsH[{{th, AddrA}}];
  assign DOAL = RegsL[{{th, AddrA}}];
  assign DOBH = RegsH[{{th, AddrB}}];
  assign DOBL = RegsL[{{th, AddrB}}];
  assign DOCH = RegsH[{{th, AddrC}}];
  assign DOCL = RegsL[{{th, AddrC}}];

endmodule
'''
open(f'{out_dir}/{REG}.v', 'w', newline='\n').write(reg)
print(f'{out_dir}/{CORE}.v: {N} contexts, {len(blocks)} clocked blocks, {len(all_names)} registers: '
      f'{" ".join(all_names)}')
