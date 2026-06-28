#!/usr/bin/env python3
"""Compare RVTRACE commits against a small RV32IMA reference model.

This is intentionally narrower than a Spike/RVVI lockstep flow. It covers the
directed tests that only need RV32IMA plus a small privileged subset, and turns
the DUT-side trace into an instruction/trap result comparison gate.
"""
import argparse
import csv
import sys


FIELDS = [
    "event",
    "cycle",
    "pc",
    "instr",
    "priv",
    "rd",
    "wdata",
    "next_pc",
    "cause",
    "tval",
]

MASK32 = 0xFFFFFFFF
MASK64 = 0xFFFFFFFFFFFFFFFF
UART_BASE = 0x10000000
SYSCON_BASE = 0x11100000
PRV_U = 0
PRV_S = 1
PRV_M = 3
SIE = 1
MIE = 3
SPIE = 5
MPIE = 7
SPP = 8
MPRV = 17
SUM_B = 18
MXR_B = 19
SSTATUS_MASK = 0x800DE722


def u32(value):
    return value & MASK32


def s32(value):
    value &= MASK32
    return value if value < 0x80000000 else value - 0x100000000


def sext(value, bits):
    sign = 1 << (bits - 1)
    return (value & (sign - 1)) - (value & sign)


def get_bit(value, bit):
    return (value >> bit) & 1


def set_bit(value, bit, enabled):
    if enabled:
        return value | (1 << bit)
    return value & ~(1 << bit)


def set_field(value, shift, mask, field):
    return (value & ~(mask << shift)) | ((field & mask) << shift)


def parse_int(text, base=0):
    try:
        return int(text, base)
    except ValueError:
        if base == 0:
            return int(text, 16)
        raise


def parse_hex(text):
    text = text.strip().lower()
    if text.startswith("0x"):
        text = text[2:]
    return int(text, 16)


def load_hex_words(path):
    words = []
    with open(path, "r", encoding="ascii") as f:
        for lineno, line in enumerate(f, 1):
            text = line.strip()
            if not text:
                continue
            try:
                words.append(int(text, 16) & MASK32)
            except ValueError as exc:
                raise ValueError(f"{path}:{lineno}: invalid hex word {text!r}") from exc
    return words


class RefError(Exception):
    pass


class Memory:
    def __init__(self, words, base, ram_size):
        self.base = base
        self.ram_size = ram_size
        self.words = {base + idx * 4: word for idx, word in enumerate(words)}
        self.uart_writes = 0
        self.syscon_writes = 0
        self.halted = False
        self.exit_code = None

    def in_ram(self, addr):
        return self.base <= addr < self.base + self.ram_size

    def _check_ram(self, addr, size):
        if not self.in_ram(addr) or not self.in_ram(addr + size - 1):
            raise RefError(f"memory access outside RAM/MMIO at 0x{addr:08x}")

    def load_u8(self, addr):
        if self._is_uart(addr):
            return self._uart_read_byte(addr)
        if self._is_syscon(addr):
            return 0
        self._check_ram(addr, 1)
        word = self.words.get(addr & ~0x3, 0)
        return (word >> ((addr & 0x3) * 8)) & 0xFF

    def load_u16(self, addr):
        if addr & 0x1:
            raise RefError(f"misaligned 16-bit load at 0x{addr:08x}")
        return self.load_u8(addr) | (self.load_u8(addr + 1) << 8)

    def load_u32(self, addr):
        if addr & 0x3:
            raise RefError(f"misaligned 32-bit load at 0x{addr:08x}")
        if self._is_uart(addr):
            byte = self._uart_read_byte(addr)
            return byte | (byte << 8) | (byte << 16) | (byte << 24)
        if self._is_syscon(addr):
            return 0
        self._check_ram(addr, 4)
        return self.words.get(addr, 0)

    def write_u32(self, addr, value):
        if addr & 0x3:
            raise RefError(f"misaligned 32-bit raw write at 0x{addr:08x}")
        self._check_ram(addr, 4)
        self.words[addr] = value & MASK32

    def store(self, addr, value, size):
        value &= MASK32
        if self._is_uart(addr):
            self.uart_writes += 1
            return None
        if self._is_syscon(addr):
            self.syscon_writes += 1
            if value == 0x5555:
                self.halted = True
                self.exit_code = 0
            elif value == 0x7777:
                self.halted = True
                self.exit_code = 1
            return None

        self._check_ram(addr, size)
        word_addr = addr & ~0x3
        old = self.words.get(word_addr, 0)
        boff = addr & 0x3

        if size == 1:
            shift = boff * 8
            mask = 0xFF << shift
            new = (old & ~mask) | ((value & 0xFF) << shift)
        elif size == 2:
            if addr & 0x1:
                raise RefError(f"misaligned 16-bit store at 0x{addr:08x}")
            shift = 16 if (boff & 0x2) else 0
            mask = 0xFFFF << shift
            new = (old & ~mask) | ((value & 0xFFFF) << shift)
        elif size == 4:
            if addr & 0x3:
                raise RefError(f"misaligned 32-bit store at 0x{addr:08x}")
            new = value
        else:
            raise RefError(f"unsupported store size {size}")

        self.words[word_addr] = new & MASK32
        return word_addr

    def _is_uart(self, addr):
        return (addr & 0xFFFFFF00) == UART_BASE

    def _is_syscon(self, addr):
        return (addr & 0xFFFFF000) == SYSCON_BASE

    def _uart_read_byte(self, addr):
        reg = addr & 0x7
        if reg == 2:
            return 0xC1
        if reg == 5:
            return 0x60
        if reg == 6:
            return 0xB0
        return 0


class RV32IMARef:
    def __init__(self, words, base, ram_size):
        self.base = base
        self.mem = Memory(words, base, ram_size)
        self.regs = [0] * 32
        self.pc = base
        self.priv = PRV_M
        self.csrs = {
            0x100: 0,  # sstatus is read/written through mstatus.
            0x105: 0,  # stvec
            0x141: 0,  # sepc
            0x142: 0,  # scause
            0x143: 0,  # stval
            0x180: 0,  # satp
            0x300: 0,  # mstatus
            0x301: 0x40141105,  # misa: MXL=1, A/C/I/M/S/U
            0x302: 0,  # medeleg
            0x303: 0,  # mideleg
            0x304: 0,  # mie
            0x305: 0,  # mtvec
            0x30A: 0,  # menvcfg
            0x31A: 0,  # menvcfgh
            0x340: 0,  # mscratch
            0x341: 0,  # mepc
            0x342: 0,  # mcause
            0x343: 0,  # mtval
            0x344: 0,  # mip
        }
        self.lr_valid = False
        self.lr_addr = 0
        self.retired = 0
        self.traps = 0
        self.priv_switches = 0
        self.writes = 0
        self.stores = 0
        self.amos = 0
        self.pte_updates = 0

    def step(self):
        pc = self.pc
        fetch = self._translate_fetch(pc)
        instr = self.mem.load_u32(fetch["pa"]) if self.mem.in_ram(fetch["pa"]) else 0
        if fetch["fault"]:
            return self._take_exception(pc, instr, 12, pc)
        if (instr & 0x3) != 0x3:
            raise RefError(f"compressed instruction at 0x{pc:08x} is outside this reference model")

        opc = instr & 0x7F
        rd = (instr >> 7) & 0x1F
        f3 = (instr >> 12) & 0x7
        rs1 = (instr >> 15) & 0x1F
        rs2 = (instr >> 20) & 0x1F
        f7 = (instr >> 25) & 0x7F
        priv = self.priv
        rv1 = self.regs[rs1]
        rv2 = self.regs[rs2]
        next_pc = u32(pc + 4)
        wb_en = False
        wb_val = 0
        store_addr = None
        d_access = None

        imm_i = sext(instr >> 20, 12)
        imm_s = sext(((instr >> 25) << 5) | ((instr >> 7) & 0x1F), 12)
        imm_b = sext(
            (((instr >> 31) & 0x1) << 12)
            | (((instr >> 7) & 0x1) << 11)
            | (((instr >> 25) & 0x3F) << 5)
            | (((instr >> 8) & 0xF) << 1),
            13,
        )
        imm_u = instr & 0xFFFFF000
        imm_j = sext(
            (((instr >> 31) & 0x1) << 20)
            | (((instr >> 12) & 0xFF) << 12)
            | (((instr >> 20) & 0x1) << 11)
            | (((instr >> 21) & 0x3FF) << 1),
            21,
        )

        if opc == 0x37:  # LUI
            wb_en = True
            wb_val = imm_u
        elif opc == 0x17:  # AUIPC
            wb_en = True
            wb_val = u32(pc + imm_u)
        elif opc == 0x6F:  # JAL
            wb_en = True
            wb_val = u32(pc + 4)
            next_pc = u32(pc + imm_j)
        elif opc == 0x67:  # JALR
            if f3 != 0:
                raise RefError(f"illegal JALR funct3={f3}")
            wb_en = True
            wb_val = u32(pc + 4)
            next_pc = u32((rv1 + imm_i) & ~0x1)
        elif opc == 0x63:  # BRANCH
            if self._branch_taken(f3, rv1, rv2):
                next_pc = u32(pc + imm_b)
        elif opc == 0x03:  # LOAD
            addr = u32(rv1 + imm_i)
            if self._load_misaligned(f3, addr):
                return self._take_exception(pc, instr, 4, addr)
            d_access = self._translate_data(addr, "load")
            if d_access["fault"]:
                return self._take_exception(pc, instr, 13, addr)
            wb_en = True
            wb_val = self._load(f3, d_access["pa"])
        elif opc == 0x23:  # STORE
            addr = u32(rv1 + imm_s)
            if self._store_misaligned(f3, addr):
                return self._take_exception(pc, instr, 6, addr)
            d_access = self._translate_data(addr, "store")
            if d_access["fault"]:
                return self._take_exception(pc, instr, 15, addr)
            store_addr = self._store(f3, d_access["pa"], rv2)
        elif opc == 0x13:  # OP-IMM
            wb_en = True
            wb_val = self._op_imm(f3, f7, rv1, imm_i)
        elif opc == 0x33:  # OP / M
            wb_en = True
            if f7 == 0x01:
                wb_val = self._muldiv(f3, rv1, rv2)
            else:
                wb_val = self._op(f3, f7, rv1, rv2)
        elif opc == 0x0F:  # FENCE/FENCE.I
            pass
        elif opc == 0x2F:  # A extension
            wb_en = True
            amo_kind = "load" if ((instr >> 27) & 0x1F) == 0b00010 else "store"
            if rv1 & 0x3:
                return self._take_exception(pc, instr, 4 if amo_kind == "load" else 6, rv1)
            d_access = self._translate_data(rv1, amo_kind)
            if d_access["fault"]:
                return self._take_exception(pc, instr, 13 if amo_kind == "load" else 15, rv1)
            wb_val, store_addr = self._amo(instr, d_access["pa"], rv2)
        elif opc == 0x73:  # SYSTEM
            system = self._system(instr, pc, rd, rs1, f3, rv1)
            if system["kind"] == "complete":
                return system["result"]
            wb_en = system["wb_en"]
            wb_val = system["wb_val"]
        else:
            raise RefError(f"unsupported opcode 0x{opc:02x} at 0x{pc:08x}")

        exp_rd = rd if wb_en and rd != 0 else 0
        exp_wdata = u32(wb_val) if exp_rd else 0

        if store_addr is not None:
            self.stores += 1
            if self.lr_valid and self.lr_addr == store_addr:
                self.lr_valid = False
        if wb_en and rd != 0:
            self.regs[rd] = u32(wb_val)
            self.writes += 1
        self.regs[0] = 0
        self._apply_ad_update(fetch)
        if d_access is not None:
            self._apply_ad_update(d_access)
        self.pc = next_pc
        self.retired += 1

        return {
            "event": "RET",
            "pc": pc,
            "instr": instr,
            "priv": priv,
            "rd": exp_rd,
            "wdata": exp_wdata,
            "next_pc": next_pc,
            "cause": 0,
            "tval": 0,
        }

    def _translate_fetch(self, va):
        return self._translate_sv32(va, "fetch", self.priv)

    def _translate_data(self, va, kind):
        mstatus = self.csrs[0x300]
        eff_priv = ((mstatus >> 11) & 0x3) if get_bit(mstatus, MPRV) else self.priv
        return self._translate_sv32(va, kind, eff_priv)

    def _translate_sv32(self, va, kind, eff_priv):
        satp = self.csrs[0x180]
        if not get_bit(satp, 31) or eff_priv == PRV_M:
            return self._xlate_ok(va, None, 0, False, False)

        vpn1 = (va >> 22) & 0x3FF
        vpn0 = (va >> 12) & 0x3FF
        root = (satp & 0x003FFFFF) << 12
        pte1_pa = u32(root + vpn1 * 4)

        if not self.mem.in_ram(pte1_pa):
            return self._xlate_fault()
        pte1 = self.mem.load_u32(pte1_pa)
        if self._pte_invalid(pte1):
            if get_bit(pte1, 0) and self._pte_leaf(pte1):
                pa = u32((((pte1 >> 20) & 0x3FF) << 22) | (va & 0x3FFFFF))
                return self._xlate_fault(pa, pte1_pa, pte1)
            return self._xlate_fault()

        if self._pte_leaf(pte1):
            leaf = pte1
            leaf_pa = pte1_pa
            pa = u32((((pte1 >> 20) & 0x3FF) << 22) | (va & 0x3FFFFF))
            if self._misaligned_superpage(pte1):
                return self._xlate_fault(pa, leaf_pa, leaf)
        else:
            pte0_pa = u32(((pte1 >> 10) & 0xFFFFF) << 12)
            pte0_pa = u32(pte0_pa + vpn0 * 4)
            if not self.mem.in_ram(pte0_pa):
                return self._xlate_fault()
            pte0 = self.mem.load_u32(pte0_pa)
            if self._pte_invalid(pte0):
                if get_bit(pte0, 0) and self._pte_leaf(pte0):
                    pa = u32((((pte0 >> 10) & 0xFFFFF) << 12) | (va & 0xFFF))
                    return self._xlate_fault(pa, pte0_pa, pte0)
                return self._xlate_fault()
            if not self._pte_leaf(pte0):
                return self._xlate_fault()
            leaf = pte0
            leaf_pa = pte0_pa
            pa = u32((((pte0 >> 10) & 0xFFFFF) << 12) | (va & 0xFFF))

        if not self._pte_perm(leaf, kind, eff_priv):
            return self._xlate_fault(pa, leaf_pa, leaf)
        set_a = not get_bit(leaf, 6)
        set_d = kind == "store" and not get_bit(leaf, 7)
        return self._xlate_ok(pa, leaf_pa, leaf, set_a, set_d)

    def _xlate_ok(self, pa, leaf_pa, leaf, set_a, set_d):
        return {
            "fault": False,
            "pa": u32(pa),
            "leaf_pa": leaf_pa,
            "leaf": leaf,
            "set_a": set_a,
            "set_d": set_d,
        }

    def _xlate_fault(self, pa=0, leaf_pa=None, leaf=0):
        return {
            "fault": True,
            "pa": u32(pa),
            "leaf_pa": leaf_pa,
            "leaf": leaf,
            "set_a": False,
            "set_d": False,
        }

    def _pte_invalid(self, pte):
        valid = get_bit(pte, 0)
        readable = get_bit(pte, 1)
        writable = get_bit(pte, 2)
        return not valid or (not readable and writable)

    def _pte_leaf(self, pte):
        return bool(get_bit(pte, 1) or get_bit(pte, 3))

    def _misaligned_superpage(self, pte):
        return ((pte >> 10) & 0x3FF) != 0

    def _pte_perm(self, pte, kind, eff_priv):
        readable = get_bit(pte, 1) or (get_bit(self.csrs[0x300], MXR_B) and get_bit(pte, 3))
        if kind == "fetch":
            access_ok = get_bit(pte, 3)
        elif kind == "load":
            access_ok = readable
        elif kind == "store":
            access_ok = get_bit(pte, 2)
        else:
            raise RefError(f"bad translation access kind {kind!r}")

        user_page = get_bit(pte, 4)
        if kind == "fetch":
            priv_ok = user_page if eff_priv == PRV_U else not user_page
        else:
            priv_ok = user_page if eff_priv == PRV_U else (not user_page or get_bit(self.csrs[0x300], SUM_B))
        return bool(access_ok and priv_ok)

    def _apply_ad_update(self, access):
        if access["leaf_pa"] is None:
            return
        new_pte = access["leaf"]
        if access["set_a"]:
            new_pte |= 0x40
        if access["set_d"]:
            new_pte |= 0x80
        if new_pte != access["leaf"]:
            self.mem.write_u32(access["leaf_pa"], new_pte)
            self.pte_updates += 1

    def _branch_taken(self, f3, a, b):
        if f3 == 0:
            return a == b
        if f3 == 1:
            return a != b
        if f3 == 4:
            return s32(a) < s32(b)
        if f3 == 5:
            return s32(a) >= s32(b)
        if f3 == 6:
            return a < b
        if f3 == 7:
            return a >= b
        raise RefError(f"illegal branch funct3={f3}")

    def _load(self, f3, addr):
        if f3 == 0:
            return u32(sext(self.mem.load_u8(addr), 8))
        if f3 == 1:
            return u32(sext(self.mem.load_u16(addr), 16))
        if f3 == 2:
            return self.mem.load_u32(addr)
        if f3 == 4:
            return self.mem.load_u8(addr)
        if f3 == 5:
            return self.mem.load_u16(addr)
        raise RefError(f"illegal load funct3={f3}")

    def _load_misaligned(self, f3, addr):
        if f3 in (0, 4):
            return False
        if f3 in (1, 5):
            return bool(addr & 0x1)
        if f3 == 2:
            return bool(addr & 0x3)
        return False

    def _store(self, f3, addr, value):
        if f3 == 0:
            return self.mem.store(addr, value, 1)
        if f3 == 1:
            return self.mem.store(addr, value, 2)
        if f3 == 2:
            return self.mem.store(addr, value, 4)
        raise RefError(f"illegal store funct3={f3}")

    def _store_misaligned(self, f3, addr):
        if f3 == 0:
            return False
        if f3 == 1:
            return bool(addr & 0x1)
        if f3 == 2:
            return bool(addr & 0x3)
        return False

    def _system(self, instr, pc, rd, rs1, f3, rv1):
        csr_addr = (instr >> 20) & 0xFFF
        f7 = (instr >> 25) & 0x7F

        if f3 == 0:
            if csr_addr == 0x000:  # ECALL
                cause = 8 if self.priv == PRV_U else 9 if self.priv == PRV_S else 11
                return {"kind": "complete", "result": self._take_exception(pc, instr, cause, 0)}
            if csr_addr == 0x001:  # EBREAK
                return {"kind": "complete", "result": self._take_exception(pc, instr, 3, 0)}
            if csr_addr == 0x302:
                return {"kind": "complete", "result": self._mret(pc, instr)}
            if csr_addr == 0x102:
                return {"kind": "complete", "result": self._sret(pc, instr)}
            if csr_addr == 0x105 or f7 == 0x09:  # WFI / SFENCE.VMA
                return {"kind": "normal", "wb_en": False, "wb_val": 0}
            raise RefError(f"unsupported SYSTEM funct3=0 csr=0x{csr_addr:03x}")

        self._check_csr_access(csr_addr)
        old = self._csr_read(csr_addr)
        src = rs1 if (f3 & 0x4) else rv1

        if (f3 & 0x3) == 1:
            write_value = src
            write = True
        elif (f3 & 0x3) == 2:
            write_value = old | src
            write = rs1 != 0
        elif (f3 & 0x3) == 3:
            write_value = old & ~src
            write = rs1 != 0
        else:
            raise RefError(f"illegal CSR funct3={f3}")

        if write:
            self._csr_write(csr_addr, write_value)
        return {"kind": "normal", "wb_en": True, "wb_val": old if rd != 0 else 0}

    def _take_exception(self, pc, instr, cause, tval):
        old_priv = self.priv
        deleg_to_s = old_priv <= PRV_S and ((self.csrs[0x302] >> cause) & 1)
        mstatus = self.csrs[0x300]

        if deleg_to_s:
            target = self.csrs[0x105] & ~0x3
            self.csrs[0x141] = pc
            self.csrs[0x142] = cause
            self.csrs[0x143] = tval
            mstatus = set_bit(mstatus, SPIE, get_bit(mstatus, SIE))
            mstatus = set_bit(mstatus, SIE, 0)
            mstatus = set_bit(mstatus, SPP, 0 if old_priv == PRV_U else 1)
            self.priv = PRV_S
        else:
            target = self.csrs[0x305] & ~0x3
            self.csrs[0x341] = pc
            self.csrs[0x342] = cause
            self.csrs[0x343] = tval
            mstatus = set_bit(mstatus, MPIE, get_bit(mstatus, MIE))
            mstatus = set_bit(mstatus, MIE, 0)
            mstatus = set_field(mstatus, 11, 0x3, old_priv)
            self.priv = PRV_M

        self.csrs[0x300] = u32(mstatus)
        self.lr_valid = False
        self.pc = u32(target)
        self.traps += 1
        if self.priv != old_priv:
            self.priv_switches += 1

        return {
            "event": "TRAP",
            "pc": pc,
            "instr": instr,
            "priv": old_priv,
            "rd": 0,
            "wdata": 0,
            "next_pc": u32(target),
            "cause": u32(cause),
            "tval": u32(tval),
        }

    def _mret(self, pc, instr):
        old_priv = self.priv
        mstatus = self.csrs[0x300]
        new_priv = (mstatus >> 11) & 0x3
        target = self.csrs[0x341]
        mstatus = set_bit(mstatus, MIE, get_bit(mstatus, MPIE))
        mstatus = set_bit(mstatus, MPIE, 1)
        mstatus = set_field(mstatus, 11, 0x3, PRV_U)
        if new_priv != PRV_M:
            mstatus = set_bit(mstatus, MPRV, 0)
        self.csrs[0x300] = u32(mstatus)
        self.priv = new_priv
        self.pc = u32(target)
        self.retired += 1
        if self.priv != old_priv:
            self.priv_switches += 1
        return self._system_ret_row(pc, instr, old_priv, target)

    def _sret(self, pc, instr):
        old_priv = self.priv
        mstatus = self.csrs[0x300]
        new_priv = PRV_S if get_bit(mstatus, SPP) else PRV_U
        target = self.csrs[0x141]
        mstatus = set_bit(mstatus, SIE, get_bit(mstatus, SPIE))
        mstatus = set_bit(mstatus, SPIE, 1)
        mstatus = set_bit(mstatus, SPP, 0)
        mstatus = set_bit(mstatus, MPRV, 0)
        self.csrs[0x300] = u32(mstatus)
        self.priv = new_priv
        self.pc = u32(target)
        self.retired += 1
        if self.priv != old_priv:
            self.priv_switches += 1
        return self._system_ret_row(pc, instr, old_priv, target)

    def _system_ret_row(self, pc, instr, priv, target):
        return {
            "event": "RET",
            "pc": pc,
            "instr": instr,
            "priv": priv,
            "rd": 0,
            "wdata": 0,
            "next_pc": u32(target),
            "cause": 0,
            "tval": 0,
        }

    def _check_csr_access(self, addr):
        min_priv = (addr >> 8) & 0x3
        if self.priv < min_priv:
            raise RefError(f"CSR 0x{addr:03x} requires priv {min_priv}, current {self.priv}")
        self._csr_read(addr)

    def _csr_read(self, addr):
        if addr == 0x100:
            return self.csrs[0x300] & SSTATUS_MASK
        if addr == 0x104:
            return self.csrs[0x304] & self.csrs[0x303]
        if addr == 0x144:
            return self.csrs[0x344] & self.csrs[0x303]
        if addr in (0x106, 0x306, 0xF11, 0xF12, 0xF13, 0xF14):
            return 0
        if addr in (0xB00, 0xC00, 0xB02, 0xC02):
            return self.retired & MASK32
        if addr in (0xB80, 0xC80, 0xB82, 0xC82, 0xC01, 0xC81):
            return 0
        if addr not in self.csrs:
            raise RefError(f"unsupported CSR 0x{addr:03x}")
        return self.csrs[addr] & MASK32

    def _csr_write(self, addr, value):
        value = u32(value)
        if addr == 0x100:
            self.csrs[0x300] = u32((self.csrs[0x300] & ~SSTATUS_MASK) | (value & SSTATUS_MASK))
        elif addr == 0x104:
            self.csrs[0x304] = u32((self.csrs[0x304] & ~self.csrs[0x303]) | (value & self.csrs[0x303]))
        elif addr == 0x144:
            self.csrs[0x344] = set_bit(self.csrs[0x344], 1, get_bit(value, 1))
        elif addr in (0x141, 0x341):
            self.csrs[addr] = value & ~1
        elif addr in (0x105, 0x140, 0x142, 0x143, 0x180,
                      0x300, 0x302, 0x303, 0x304, 0x305,
                      0x340, 0x342, 0x343, 0x344):
            self.csrs[addr] = value
        elif addr == 0x30A:
            self.csrs[addr] = 0
        elif addr == 0x31A:
            self.csrs[addr] = value & 0x20000000
        elif addr in (0x106, 0x306, 0x301, 0xF11, 0xF12, 0xF13, 0xF14,
                      0xB00, 0xC00, 0xB80, 0xC80, 0xB02, 0xC02, 0xB82, 0xC82,
                      0xC01, 0xC81):
            pass
        else:
            raise RefError(f"unsupported CSR write 0x{addr:03x}")

    def _op_imm(self, f3, f7, a, imm):
        shamt = imm & 0x1F
        if f3 == 0:
            return u32(a + imm)
        if f3 == 1:
            if f7 != 0:
                raise RefError(f"illegal SLLI funct7=0x{f7:02x}")
            return u32(a << shamt)
        if f3 == 2:
            return 1 if s32(a) < imm else 0
        if f3 == 3:
            return 1 if a < u32(imm) else 0
        if f3 == 4:
            return u32(a ^ imm)
        if f3 == 5:
            if f7 == 0x00:
                return a >> shamt
            if f7 == 0x20:
                return u32(s32(a) >> shamt)
            raise RefError(f"illegal SRLI/SRAI funct7=0x{f7:02x}")
        if f3 == 6:
            return u32(a | imm)
        if f3 == 7:
            return u32(a & imm)
        raise RefError(f"illegal OP-IMM funct3={f3}")

    def _op(self, f3, f7, a, b):
        shamt = b & 0x1F
        if f3 == 0:
            if f7 == 0x00:
                return u32(a + b)
            if f7 == 0x20:
                return u32(a - b)
            raise RefError(f"illegal ADD/SUB funct7=0x{f7:02x}")
        if f3 == 1:
            if f7 != 0:
                raise RefError(f"illegal SLL funct7=0x{f7:02x}")
            return u32(a << shamt)
        if f3 == 2:
            if f7 != 0:
                raise RefError(f"illegal SLT funct7=0x{f7:02x}")
            return 1 if s32(a) < s32(b) else 0
        if f3 == 3:
            if f7 != 0:
                raise RefError(f"illegal SLTU funct7=0x{f7:02x}")
            return 1 if a < b else 0
        if f3 == 4:
            if f7 != 0:
                raise RefError(f"illegal XOR funct7=0x{f7:02x}")
            return u32(a ^ b)
        if f3 == 5:
            if f7 == 0x00:
                return a >> shamt
            if f7 == 0x20:
                return u32(s32(a) >> shamt)
            raise RefError(f"illegal SRL/SRA funct7=0x{f7:02x}")
        if f3 == 6:
            if f7 != 0:
                raise RefError(f"illegal OR funct7=0x{f7:02x}")
            return u32(a | b)
        if f3 == 7:
            if f7 != 0:
                raise RefError(f"illegal AND funct7=0x{f7:02x}")
            return u32(a & b)
        raise RefError(f"illegal OP funct3={f3}")

    def _muldiv(self, f3, a, b):
        if f3 == 0:
            return u32(s32(a) * s32(b))
        if f3 == 1:
            return ((s32(a) * s32(b)) & MASK64) >> 32
        if f3 == 2:
            return ((s32(a) * b) & MASK64) >> 32
        if f3 == 3:
            return ((a * b) & MASK64) >> 32
        if f3 == 4:
            if b == 0:
                return MASK32
            if a == 0x80000000 and b == MASK32:
                return 0x80000000
            return u32(trunc_div(s32(a), s32(b)))
        if f3 == 5:
            return MASK32 if b == 0 else a // b
        if f3 == 6:
            if b == 0:
                return a
            if a == 0x80000000 and b == MASK32:
                return 0
            return u32(trunc_rem(s32(a), s32(b)))
        if f3 == 7:
            return a if b == 0 else a % b
        raise RefError(f"illegal M funct3={f3}")

    def _amo(self, instr, addr, rs2_value):
        rd = (instr >> 7) & 0x1F
        f3 = (instr >> 12) & 0x7
        rs2 = (instr >> 20) & 0x1F
        f5 = (instr >> 27) & 0x1F
        if f3 != 2:
            raise RefError(f"illegal AMO funct3={f3}")
        if addr & 0x3:
            raise RefError(f"misaligned AMO at 0x{addr:08x}")

        old = self.mem.load_u32(addr)
        store_addr = None

        if f5 == 0b00010:  # LR.W
            if rs2 != 0:
                raise RefError("LR.W with nonzero rs2")
            self.lr_valid = True
            self.lr_addr = addr
        elif f5 == 0b00011:  # SC.W
            ok = self.lr_valid and self.lr_addr == addr
            if ok:
                store_addr = self.mem.store(addr, rs2_value, 4)
            self.lr_valid = False
            return (0 if ok else 1), store_addr
        else:
            new = self._amo_result(f5, old, rs2_value)
            store_addr = self.mem.store(addr, new, 4)
            self.amos += 1

        return old if rd != 0 else 0, store_addr

    def _amo_result(self, f5, old, value):
        if f5 == 0b00001:
            return value
        if f5 == 0b00000:
            return u32(old + value)
        if f5 == 0b00100:
            return u32(old ^ value)
        if f5 == 0b01100:
            return u32(old & value)
        if f5 == 0b01000:
            return u32(old | value)
        if f5 == 0b10000:
            return old if s32(old) < s32(value) else value
        if f5 == 0b10100:
            return old if s32(old) > s32(value) else value
        if f5 == 0b11000:
            return old if old < value else value
        if f5 == 0b11100:
            return old if old > value else value
        raise RefError(f"unsupported AMO funct5=0x{f5:02x}")


def trunc_div(a, b):
    q = abs(a) // abs(b)
    return -q if (a < 0) ^ (b < 0) else q


def trunc_rem(a, b):
    return a - trunc_div(a, b) * b


def compare_field(errors, line, name, got, exp):
    if got != exp:
        errors.append(f"line {line}: {name} mismatch trace=0x{got:08x} ref=0x{exp:08x}")


def print_errors(errors):
    print("RVTRACE_REF: FAIL", file=sys.stderr)
    for msg in errors:
        print(f"  {msg}", file=sys.stderr)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--trace", required=True, help="RVTRACE CSV file")
    ap.add_argument("--hex", required=True, help="little-endian word hex image")
    ap.add_argument("--base", default="0x80000000", help="RAM base address")
    ap.add_argument("--ram-size", default="0x4000000", help="RAM size in bytes")
    ap.add_argument("--expect-priv", type=lambda text: parse_int(text), help="optional extra privilege constraint")
    ap.add_argument("--max-errors", type=int, default=20, help="stop after this many errors")
    args = ap.parse_args()

    base = parse_int(args.base)
    ram_size = parse_int(args.ram_size)
    words = load_hex_words(args.hex)
    ref = RV32IMARef(words, base, ram_size)
    errors = []
    row_total = 0

    with open(args.trace, "r", encoding="ascii", newline="") as f:
        reader = csv.DictReader(f)
        if reader.fieldnames != FIELDS:
            print_errors([f"bad header: got {reader.fieldnames}, expected {FIELDS}"])
            return 1

        for line, row in enumerate(reader, 2):
            row_total += 1
            try:
                event = row["event"]
                pc = parse_hex(row["pc"])
                instr = parse_hex(row["instr"])
                priv = parse_int(row["priv"], 10)
                rd = parse_int(row["rd"], 10)
                wdata = parse_hex(row["wdata"])
                next_pc = parse_hex(row["next_pc"])
                cause = parse_hex(row["cause"])
                tval = parse_hex(row["tval"])
            except ValueError as exc:
                errors.append(f"line {line}: bad field: {exc}")
                if len(errors) >= args.max_errors:
                    break
                continue

            try:
                exp = ref.step()
            except RefError as exc:
                errors.append(f"line {line}: reference step failed: {exc}")
                break

            if event != exp["event"]:
                errors.append(f"line {line}: event mismatch trace={event} ref={exp['event']}")
            compare_field(errors, line, "pc", pc, exp["pc"])
            compare_field(errors, line, "instr", instr, exp["instr"])
            if priv != exp["priv"]:
                errors.append(f"line {line}: priv mismatch trace={priv} ref={exp['priv']}")
            if args.expect_priv is not None and priv != args.expect_priv:
                errors.append(f"line {line}: priv {priv} violates --expect-priv {args.expect_priv}")
            if rd != exp["rd"]:
                errors.append(f"line {line}: rd mismatch trace={rd} ref={exp['rd']}")
            compare_field(errors, line, "wdata", wdata, exp["wdata"])
            compare_field(errors, line, "next_pc", next_pc, exp["next_pc"])
            compare_field(errors, line, "cause", cause, exp["cause"])
            compare_field(errors, line, "tval", tval, exp["tval"])

            if len(errors) >= args.max_errors:
                break

    if row_total == 0:
        errors.append("trace contains no data rows")

    if errors:
        print_errors(errors)
        return 1

    print(
        "RVTRACE_REF: PASS "
        f"rows={row_total} retired={ref.retired} traps={ref.traps} "
        f"priv_switches={ref.priv_switches} writes={ref.writes} stores={ref.stores} "
        f"amos={ref.amos} pte_updates={ref.pte_updates} "
        f"uart_writes={ref.mem.uart_writes} syscon_writes={ref.mem.syscon_writes} "
        f"halted={int(ref.mem.halted)} exit={ref.mem.exit_code if ref.mem.exit_code is not None else 'none'}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
