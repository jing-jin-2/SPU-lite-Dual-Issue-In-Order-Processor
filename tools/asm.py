#!/usr/bin/env python3
"""
SPU-lite assembler.

Reads an assembly source file (one instruction per line, comments with `#` or `;`,
labels of the form `name:`) and emits a hex file suitable for $readmemh.

Bundle convention: even-pipe instruction first, odd-pipe second. The assembler
does NOT enforce dual-issue rules -- it just emits one 32-bit word per source
line.  Use `nop` to fill an even slot, `lnop` to fill an odd slot.

Encoding follows the Cell SPU ISA v1.2 exactly. Bit numbering in this file is
standard SystemVerilog [31:0] -- bit 31 is the MSB.

Field layout per format:
  RR    : opcode[31:21] | RB[20:14] | RA[13:7] | RT[6:0]
  RRR   : opcode[31:28] | RT[27:21] | RB[20:14] | RA[13:7] | RC[6:0]
  RI7   : opcode[31:21] | I7[20:14] | RA[13:7] | RT[6:0]
  RI8   : opcode[31:22] | I8[21:14] | RA[13:7] | RT[6:0]
  RI10  : opcode[31:24] | I10[23:14] | RA[13:7] | RT[6:0]
  RI16  : opcode[31:23] | I16[22:7] | RT[6:0]
  RI18  : opcode[31:25] | I18[24:7] | RT[6:0]

Usage:
  python3 tools/asm.py program.s -o program.hex

Pseudo-mnemonics handled:
  shra   rt,ra,rb     -> rotma  rt,ra,rb         (logical: shift = -count mod 64)
  shrai  rt,ra,imm    -> rotmai rt,ra,(-imm & 0x7F)   (immediate already negated)
"""

import argparse
import re
import sys
from typing import Dict, List, Tuple, Optional

# ------------------------------------------------------------------------------
#  Opcode table.
#  Each entry: (mnemonic, format, opcode_bits)
#  opcode_bits is the constant high-bit pattern as a Python int, left-aligned
#  to bit 31.  Format determines how operands are placed.
# ------------------------------------------------------------------------------

# Format codes:
#   RR   = 3-register     (op[31:21], rb[20:14], ra[13:7], rt[6:0])
#   RR2  = 2-register     (op[31:21], ra[13:7], rt[6:0])    -- for unary ops, RB unused
#   RR1  = 1-register     (op[31:21], ra[13:7])             -- for halt/etc, RT is "false target"
#   RRR  = 4-register     (op[31:28], rt[27:21], rb[20:14], ra[13:7], rc[6:0])
#   RI7  = 7-bit imm      (op[31:21], i7[20:14], ra[13:7], rt[6:0])
#   RI8  = 8-bit imm      (op[31:22], i8[21:14], ra[13:7], rt[6:0])
#   RI10 = 10-bit imm     (op[31:24], i10[23:14], ra[13:7], rt[6:0])
#   RI16 = 16-bit imm     (op[31:23], i16[22:7], rt[6:0])
#   RI18 = 18-bit imm     (op[31:25], i18[24:7], rt[6:0])
#   BR_R = branch indirect (op[31:21], ra[13:7], rt[6:0])  -- feature bits in [16:14]
#   BR_T = branch on cond (op[31:23], i16[22:7], rt[6:0])  -- same as RI16
#   STOP = stop instr     (op[31:21], stop_type[13:0])
#   NOP_E = even nop      (op[31:21], rt[6:0])             -- RT is false target
#   NOP_L = load nop      (op[31:21], rt[6:0])             -- RT field reads as zero
#
# All opcode patterns are taken from the Cell SPU ISA v1.2 (Jan 27, 2007).

OPCODES: Dict[str, Tuple[str, int]] = {
    # -- Memory: Load/Store (odd pipe, LS unit) --
    'lqd':       ('RI10', 0b00110100),
    'lqx':       ('RR',   0b00111000100),
    'lqa':       ('RI16', 0b001100001),
    'lqr':       ('RI16', 0b001100111),
    'stqd':      ('RI10', 0b00100100),
    'stqx':      ('RR',   0b00101000100),
    'stqa':      ('RI16', 0b001000001),
    'stqr':      ('RI16', 0b001000111),
    'cbd':       ('RI7',  0b00111110100),
    'cbx':       ('RR',   0b00111010100),
    'chd':       ('RI7',  0b00111110101),
    'chx':       ('RR',   0b00111010101),
    'cwd':       ('RI7',  0b00111110110),
    'cwx':       ('RR',   0b00111010110),
    'cdd':       ('RI7',  0b00111110111),
    'cdx':       ('RR',   0b00111010111),

    # -- Constant-formation (even pipe) --
    'ilh':       ('RI16', 0b010000011),
    'ilhu':      ('RI16', 0b010000010),
    'il':        ('RI16', 0b010000001),
    'ila':       ('RI18', 0b0100001),
    'iohl':      ('RI16', 0b011000001),
    'fsmbi':     ('RI16', 0b001100101),

    # -- Integer/Logical arithmetic (FX1, even, lat 2) --
    'ah':        ('RR',   0b00011001000),
    'ahi':       ('RI10', 0b00011101),
    'a':         ('RR',   0b00011000000),
    'ai':        ('RI10', 0b00011100),
    'sfh':       ('RR',   0b00001001000),
    'sfhi':      ('RI10', 0b00001101),
    'sf':        ('RR',   0b00001000000),
    'sfi':       ('RI10', 0b00001100),
    'addx':      ('RR',   0b01101000000),
    'cg':        ('RR',   0b00011000010),
    'cgx':       ('RR',   0b01101000010),
    'sfx':       ('RR',   0b01101000001),
    'bg':        ('RR',   0b00001000010),
    'bgx':       ('RR',   0b01101000011),

    # -- Multiply (FP unit, even) --
    'mpy':       ('RR',   0b01111000100),
    'mpyu':      ('RR',   0b01111001100),
    'mpyi':      ('RI10', 0b01110100),
    'mpyui':     ('RI10', 0b01110101),
    'mpya':      ('RRR',  0b1100),
    'mpyh':      ('RR',   0b01111000101),
    'mpys':      ('RR',   0b01111000111),
    'mpyhh':     ('RR',   0b01111000110),
    'mpyhha':    ('RR',   0b01101000110),
    'mpyhhu':    ('RR',   0b01111001110),
    'mpyhhau':   ('RR',   0b01101001110),

    # -- Logical / Bitwise (FX2, even) --
    'and':       ('RR',   0b00011000001),
    'andc':      ('RR',   0b01011000001),
    'andbi':     ('RI10', 0b00010110),
    'andhi':     ('RI10', 0b00010101),
    'andi':      ('RI10', 0b00010100),
    'or':        ('RR',   0b00001000001),
    'orc':       ('RR',   0b01011001001),
    'orbi':      ('RI10', 0b00000110),
    'orhi':      ('RI10', 0b00000101),
    'ori':       ('RI10', 0b00000100),
    'orx':       ('RR2',  0b00111110000),
    'xor':       ('RR',   0b01001000001),
    'xorbi':     ('RI10', 0b01000110),
    'xorhi':     ('RI10', 0b01000101),
    'xori':      ('RI10', 0b01000100),
    'nand':      ('RR',   0b00011001001),
    'nor':       ('RR',   0b00001001001),
    'eqv':       ('RR',   0b01001001001),
    'selb':      ('RRR',  0b1000),
    'shufb':     ('RRR',  0b1011),

    # -- Byte unit (even, lat 4) --
    'clz':       ('RR2',  0b01010100101),
    'cntb':      ('RR2',  0b01010110100),
    'fsmb':      ('RR2',  0b00110110110),
    'fsmh':      ('RR2',  0b00110110101),
    'fsm':       ('RR2',  0b00110110100),
    'gbb':       ('RR2',  0b00110110010),
    'gbh':       ('RR2',  0b00110110001),
    'gb':        ('RR2',  0b00110110000),
    'avgb':      ('RR',   0b00011010011),
    'absdb':     ('RR',   0b00001010011),
    'sumb':      ('RR',   0b01001010011),
    'xsbh':      ('RR2',  0b01010110110),
    'xshw':      ('RR2',  0b01010101110),
    'xswd':      ('RR2',  0b01010100110),

    # -- Shift / Rotate (FX2, even) --
    'shlh':      ('RR',   0b00001011111),
    'shlhi':     ('RI7',  0b00001111111),
    'shl':       ('RR',   0b00001011011),
    'shli':      ('RI7',  0b00001111011),
    'roth':      ('RR',   0b00001011100),
    'rothi':     ('RI7',  0b00001111100),
    'rot':       ('RR',   0b00001011000),
    'roti':      ('RI7',  0b00001111000),
    'rotma':     ('RR',   0b00001011010),
    'rotmai':    ('RI7',  0b00001111010),
    'rothm':     ('RR',   0b00001011101),
    'rothmi':    ('RI7',  0b00001111101),
    'rotm':      ('RR',   0b00001011001),
    'rotmi':     ('RI7',  0b00001111001),
    'rotmah':    ('RR',   0b00001011110),
    'rotmahi':   ('RI7',  0b00001111110),

    # -- Permute (odd pipe, PERM unit) --
    'shlqbi':    ('RR',   0b00111011011),
    'shlqbii':   ('RI7',  0b00111111011),
    'shlqby':    ('RR',   0b00111011111),
    'shlqbyi':   ('RI7',  0b00111111111),
    'shlqbybi':  ('RR',   0b00111001111),
    'rotqby':    ('RR',   0b00111011100),
    'rotqbyi':   ('RI7',  0b00111111100),
    'rotqbybi':  ('RR',   0b00111001100),
    'rotqbi':    ('RR',   0b00111011000),
    'rotqbii':   ('RI7',  0b00111111000),
    'rotqmby':   ('RR',   0b00111011101),
    'rotqmbyi':  ('RI7',  0b00111111101),
    'rotqmbybi': ('RR',   0b00111001101),
    'rotqmbi':   ('RR',   0b00111011001),
    'rotqmbii':  ('RI7',  0b00111111001),

    # -- Compare (even pipe, FX1) --
    'ceqb':      ('RR',   0b01111010000),
    'ceqbi':     ('RI10', 0b01111110),
    'ceqh':      ('RR',   0b01111001000),
    'ceqhi':     ('RI10', 0b01111101),
    'ceq':       ('RR',   0b01111000000),
    'ceqi':      ('RI10', 0b01111100),
    'cgtb':      ('RR',   0b01001010000),
    'cgtbi':     ('RI10', 0b01001110),
    'cgth':      ('RR',   0b01001001000),
    'cgthi':     ('RI10', 0b01001101),
    'cgt':       ('RR',   0b01001000000),
    'cgti':      ('RI10', 0b01001100),
    'clgtb':     ('RR',   0b01011010000),
    'clgtbi':    ('RI10', 0b01011110),
    'clgth':     ('RR',   0b01011001000),
    'clgthi':    ('RI10', 0b01011101),
    'clgt':      ('RR',   0b01011000000),
    'clgti':     ('RI10', 0b01011100),

    # -- Branch (odd pipe, BR unit) --
    'br':        ('RI16', 0b001100100),  # PC-relative
    'bra':       ('RI16', 0b001100000),  # absolute
    'brsl':      ('RI16', 0b001100110),  # PC-rel + link
    'brasl':     ('RI16', 0b001100010),  # absolute + link
    'brnz':      ('RI16', 0b001000010),
    'brz':       ('RI16', 0b001000000),
    'brhnz':     ('RI16', 0b001000110),
    'brhz':      ('RI16', 0b001000100),
    'bi':        ('BR_R', 0b00110101000),
    'biz':       ('BR_R', 0b00100101000),
    'binz':      ('BR_R', 0b00100101001),
    'bihz':      ('BR_R', 0b00100101010),
    'bihnz':     ('BR_R', 0b00100101011),
    'bisl':      ('BR_R', 0b00110101001),
    'bisled':    ('BR_R', 0b00110101011),
    'iret':      ('BR_R', 0b00110101010),

    # -- Floating point single-precision (even, FP) --
    'fa':        ('RR',   0b01011000100),
    'fs':        ('RR',   0b01011000101),
    'fm':        ('RR',   0b01011000110),
    'fma':       ('RRR',  0b1110),
    'fms':       ('RRR',  0b1111),
    'fnms':      ('RRR',  0b1101),
    'fceq':      ('RR',   0b01111000010),
    'fcgt':      ('RR',   0b01011000010),
    'fcmeq':     ('RR',   0b01111001010),
    'fcmgt':     ('RR',   0b01011001010),
    'frest':     ('RR2',  0b00110111000),
    'frsqest':   ('RR2',  0b00110111001),
    'fi':        ('RR',   0b01111010100),
    'csflt':     ('RI8',  0b0111011010),
    'cflts':     ('RI8',  0b0111011000),
    'cuflt':     ('RI8',  0b0111011011),
    'cfltu':     ('RI8',  0b0111011001),

    # -- Control / Channel --
    'stop':      ('STOP',  0b00000000000),
    'lnop':      ('NOP_L', 0b00000000001),
    'nop':       ('NOP_E', 0b01000000001),
    'sync':      ('NOP_L', 0b00000000010),
    'dsync':     ('NOP_L', 0b00000000011),
}


# Format -> opcode width (bits) lookup, used to position the opcode at the top.
OPCODE_WIDTH = {
    'RR':    11, 'RR2':   11, 'RR1':   11,
    'RRR':    4,
    'RI7':   11,
    'RI8':   10,
    'RI10':   8,
    'RI16':   9,
    'RI18':   7,
    'BR_R':  11,
    'BR_T':   9,
    'STOP':  11,
    'NOP_E': 11, 'NOP_L': 11,
}


def parse_reg(tok: str) -> int:
    """Parse a register operand: 'r5', '$5', '5'."""
    tok = tok.strip().lower()
    if tok.startswith('r') or tok.startswith('$'):
        tok = tok[1:]
    n = int(tok, 0)
    if not 0 <= n <= 127:
        raise ValueError(f"register out of range: {tok}")
    return n


def parse_imm(tok: str, bits: int, signed: bool, labels: Dict[str, int],
              pc: int) -> int:
    """Parse an immediate.  Supports decimal, 0x..., 0b..., or a label name.
    For labels, returns label_addr - pc (PC-relative word offset for branches)
    only when caller asks for it via signed=True and pc>=0; otherwise label
    resolves to its absolute byte address.

    `bits` is the field width.  `signed` controls range checking and masking.
    """
    tok = tok.strip()
    if not tok:
        raise ValueError("empty immediate")

    # Label reference (PC-relative word offset, will be adjusted by caller)
    if tok in labels:
        return labels[tok]

    # Numeric literal
    val = int(tok, 0)
    mask = (1 << bits) - 1
    # Accept any value whose low `bits` bits unambiguously represent the
    # operand: signed range [-2^(b-1), 2^(b-1)-1] OR unsigned [0, 2^b-1].
    # Reject anything outside both -- that's almost certainly a bug like
    # passing a 20-bit literal to an 18-bit field.
    lo = -(1 << (bits - 1))
    hi = mask  # accept up to unsigned max even for signed fields
    if not lo <= val <= hi:
        kind = "signed" if signed else "unsigned"
        raise ValueError(
            f"immediate {tok} ({val}, 0x{val:X}) does not fit in {bits}-bit "
            f"{kind} field (allowed {lo}..0x{hi:X})")
    return val & mask


def split_operands(s: str) -> List[str]:
    """Split an operand string on commas, but keep parenthesized groups.
    e.g.  'r1, 10(r2)' -> ['r1', '10(r2)']
    """
    out = []
    depth = 0
    cur = ''
    for ch in s:
        if ch == '(':
            depth += 1; cur += ch
        elif ch == ')':
            depth -= 1; cur += ch
        elif ch == ',' and depth == 0:
            out.append(cur.strip()); cur = ''
        else:
            cur += ch
    if cur.strip():
        out.append(cur.strip())
    return out


def parse_d_form(operand: str) -> Tuple[int, str]:
    """Parse `imm(ra)` form for d-form load/store. Returns (imm, ra_str)."""
    m = re.match(r'^\s*(.+?)\s*\(\s*(\S+)\s*\)\s*$', operand)
    if not m:
        raise ValueError(f"bad d-form operand: {operand!r}, expected imm(reg)")
    return m.group(1), m.group(2)


def encode_instruction(mnemonic: str, operands: List[str],
                       labels: Dict[str, int], pc: int) -> int:
    """Encode a single instruction to a 32-bit word."""
    mnemonic = mnemonic.lower()

    # -- Pseudo-mnemonics for arithmetic right shift --
    # SPU has no `shra` per se; it's encoded as `rotma` with a negated count
    # (which the user supplies as the "shift amount" -- assembler does the negation).
    if mnemonic == 'shra':
        mnemonic = 'rotma'
    elif mnemonic == 'shrai':
        # operand 3 is the shift amount; replace with two's-complement-mod-128
        if len(operands) >= 3:
            try:
                v = int(operands[2], 0)
                operands = operands[:2] + [str((-v) & 0x7F)]
            except ValueError:
                pass
        mnemonic = 'rotmai'
    elif mnemonic == 'shrah':
        mnemonic = 'rotmah'
    elif mnemonic == 'shrahi':
        if len(operands) >= 3:
            try:
                v = int(operands[2], 0)
                operands = operands[:2] + [str((-v) & 0x7F)]
            except ValueError:
                pass
        mnemonic = 'rotmahi'

    if mnemonic not in OPCODES:
        raise ValueError(f"unknown mnemonic: {mnemonic!r}")

    fmt, op = OPCODES[mnemonic]
    width = OPCODE_WIDTH[fmt]
    op_shift = 32 - width
    word = (op & ((1 << width) - 1)) << op_shift

    if fmt == 'RR':
        # rt, ra, rb
        rt, ra, rb = (parse_reg(x) for x in operands)
        word |= (rb & 0x7F) << 14
        word |= (ra & 0x7F) << 7
        word |= (rt & 0x7F)
    elif fmt == 'RR2':
        # rt, ra
        rt, ra = (parse_reg(x) for x in operands)
        word |= (ra & 0x7F) << 7
        word |= (rt & 0x7F)
    elif fmt == 'RR1':
        # ra (no rt)
        ra = parse_reg(operands[0])
        word |= (ra & 0x7F) << 7
    elif fmt == 'RRR':
        # rt, ra, rb, rc
        rt, ra, rb, rc = (parse_reg(x) for x in operands)
        word |= (rt & 0x7F) << 21
        word |= (rb & 0x7F) << 14
        word |= (ra & 0x7F) << 7
        word |= (rc & 0x7F)
    elif fmt == 'RI7':
        # rt, ra, imm7
        rt, ra = parse_reg(operands[0]), parse_reg(operands[1])
        imm = parse_imm(operands[2], 7, signed=True, labels=labels, pc=pc)
        word |= (imm & 0x7F) << 14
        word |= (ra & 0x7F) << 7
        word |= (rt & 0x7F)
    elif fmt == 'RI8':
        # rt, ra, imm8 (e.g., csflt scale)
        rt, ra = parse_reg(operands[0]), parse_reg(operands[1])
        imm = parse_imm(operands[2], 8, signed=False, labels=labels, pc=pc)
        word |= (imm & 0xFF) << 14
        word |= (ra & 0x7F) << 7
        word |= (rt & 0x7F)
    elif fmt == 'RI10':
        # rt, ra, imm10  OR  rt, imm(ra)  for d-form load/store
        if len(operands) == 2 and '(' in operands[1]:
            rt = parse_reg(operands[0])
            imm_str, ra_str = parse_d_form(operands[1])
            ra = parse_reg(ra_str)
            # For lqd/stqd, the 10-bit immediate is a quadword offset:
            # the encoded value is byte_offset >> 4.
            raw = parse_imm(imm_str, 14, signed=True, labels=labels, pc=pc)
            if mnemonic in ('lqd', 'stqd'):
                imm = (raw >> 4) & 0x3FF
            else:
                imm = raw & 0x3FF
        else:
            rt = parse_reg(operands[0])
            ra = parse_reg(operands[1])
            imm = parse_imm(operands[2], 10, signed=True, labels=labels, pc=pc)
        word |= (imm & 0x3FF) << 14
        word |= (ra & 0x7F) << 7
        word |= (rt & 0x7F)
    elif fmt == 'RI16':
        # Two shapes:
        #   ilh/ilhu/il/iohl/fsmbi:  rt, imm
        #   br/bra:                   imm
        #   brsl/brasl/brz/brnz/...:  rt, label   (PC-relative for br/brsl/brz/brnz/brhz/brhnz)
        #   lqa/stqa:                 rt, addr   (absolute, byte addr; encoded as addr>>2)
        is_pc_rel  = mnemonic in ('br', 'brsl', 'brz', 'brnz', 'brhz', 'brhnz', 'lqr', 'stqr')
        is_abs_q   = mnemonic in ('lqa', 'stqa', 'bra', 'brasl')
        # Operand layout
        if mnemonic in ('br', 'bra'):
            rt = 0
            target = operands[0]
        else:
            rt = parse_reg(operands[0])
            target = operands[1]

        # Resolve target -- could be label or numeric
        target_s = target.strip()
        if target_s in labels:
            tgt = labels[target_s]
            if is_pc_rel:
                # 16-bit immediate is the (target - pc) >> 2 word offset
                offs = (tgt - pc) >> 2
                imm = offs & 0xFFFF
            else:
                # Absolute byte address: encode as addr >> 2
                imm = (tgt >> 2) & 0xFFFF
        else:
            # Numeric literal -- for lqa/stqa/bra/brasl/lqr/stqr/br/brsl/brz/brnz/...
            # the address is in bytes; encoded I16 is addr>>2.  For other RI16
            # mnemonics (ilh/ilhu/il/iohl/fsmbi) the literal is the raw value.
            raw = parse_imm(target_s, 16, signed=True, labels=labels, pc=pc)
            if is_pc_rel or is_abs_q:
                # Shift the signed byte value before masking; shifting the
                # masked value turns negative offsets into positive offsets.
                imm = (int(target_s, 0) >> 2) & 0xFFFF
            else:
                imm = raw & 0xFFFF

        word |= (imm & 0xFFFF) << 7
        word |= (rt & 0x7F)
    elif fmt == 'RI18':
        # ila rt, imm18 (or label: absolute byte address, low 18 bits)
        rt = parse_reg(operands[0])
        target = operands[1].strip()
        if target in labels:
            imm = labels[target] & 0x3FFFF
        else:
            imm = parse_imm(target, 18, signed=False, labels=labels, pc=pc) & 0x3FFFF
        word |= (imm & 0x3FFFF) << 7
        word |= (rt & 0x7F)
    elif fmt == 'BR_R':
        # bi/bisl/bisled/biz/binz/bihz/bihnz/iret  ra
        # bisl/bisled/biz/binz/bihz/bihnz also have RT
        if mnemonic in ('bi', 'iret'):
            ra = parse_reg(operands[0])
            rt = 0
        else:
            rt = parse_reg(operands[0])
            ra = parse_reg(operands[1])
        word |= (ra & 0x7F) << 7
        word |= (rt & 0x7F)
    elif fmt == 'STOP':
        # stop [type]
        stop_type = 0
        if operands:
            stop_type = parse_imm(operands[0], 14, signed=False,
                                  labels=labels, pc=pc) & 0x3FFF
        word |= stop_type & 0x3FFF
    elif fmt == 'NOP_E':
        # nop [rt]   -- RT is a false target, optional
        if operands:
            word |= parse_reg(operands[0]) & 0x7F
    elif fmt == 'NOP_L':
        # lnop / sync / dsync -- no operands
        pass
    else:
        raise ValueError(f"internal: unhandled format {fmt}")

    return word & 0xFFFFFFFF


# ------------------------------------------------------------------------------
#  Two-pass assembly: pass 1 collects labels, pass 2 emits machine code.
# ------------------------------------------------------------------------------

LABEL_RE = re.compile(r'^([A-Za-z_][\w]*)\s*:\s*(.*)$')


def strip_comment(line: str) -> str:
    """Remove `#` or `;` comments."""
    for c in ('#', ';'):
        i = line.find(c)
        if i >= 0:
            line = line[:i]
    return line.rstrip()


def assemble(source: str) -> List[int]:
    """Assemble source text into a list of 32-bit instruction words."""
    lines = source.splitlines()

    # Pass 1: collect labels with their byte addresses (PC values)
    labels: Dict[str, int] = {}
    pc = 0
    parsed: List[Tuple[int, str, str, List[str]]] = []  # (pc, line_no, mnemonic, operands)
    for lineno, raw in enumerate(lines, start=1):
        line = strip_comment(raw).strip()
        while line:
            m = LABEL_RE.match(line)
            if m:
                lab = m.group(1)
                if lab in labels:
                    raise SyntaxError(f"line {lineno}: duplicate label {lab!r}")
                labels[lab] = pc
                line = m.group(2).strip()
                continue
            break
        if not line:
            continue
        parts = line.split(None, 1)
        mnemonic = parts[0].lower()
        rest = parts[1] if len(parts) > 1 else ''
        operands = split_operands(rest)
        parsed.append((pc, lineno, mnemonic, operands))
        pc += 4

    # Pass 2: emit
    out: List[int] = []
    for pc, lineno, mnemonic, operands in parsed:
        try:
            word = encode_instruction(mnemonic, operands, labels, pc)
        except Exception as e:
            raise SyntaxError(f"line {lineno}: {mnemonic} {','.join(operands)}: {e}")
        out.append(word)
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description="SPU-lite assembler")
    ap.add_argument('source', help="assembly source file (.s)")
    ap.add_argument('-o', '--output', help="output hex file (default: <source>.hex)")
    ap.add_argument('--depth', type=int, default=512,
                    help="IMEM depth in words; output is padded with zeros")
    args = ap.parse_args()

    with open(args.source) as f:
        src = f.read()

    try:
        words = assemble(src)
    except SyntaxError as e:
        print(f"error: {e}", file=sys.stderr)
        return 1

    if len(words) > args.depth:
        print(f"error: program is {len(words)} words but IMEM depth is {args.depth}",
              file=sys.stderr)
        return 1

    out = args.output or (args.source.rsplit('.', 1)[0] + '.hex')
    with open(out, 'w') as f:
        for w in words:
            f.write(f"{w:08x}\n")
        # Pad with zero-NOPs (HW-NOP, all zeros) to fill IMEM
        for _ in range(args.depth - len(words)):
            f.write("00000000\n")

    print(f"assembled {len(words)} instructions -> {out}")
    return 0


if __name__ == '__main__':
    sys.exit(main())
