#!/usr/bin/env python3
"""极简 RV32I 汇编器: prog.s -> prog.hex ($readmemh 可读的十六进制)。
支持本 CPU 核实现的指令子集 + 常用伪指令 + 标签。两遍扫描。"""
import sys, re

ABI = {
    'zero':0,'ra':1,'sp':2,'gp':3,'tp':4,'t0':5,'t1':6,'t2':7,
    's0':8,'fp':8,'s1':9,'a0':10,'a1':11,'a2':12,'a3':13,'a4':14,'a5':15,
    'a6':16,'a7':17,'s2':18,'s3':19,'s4':20,'s5':21,'s6':22,'s7':23,
    's8':24,'s9':25,'s10':26,'s11':27,'t3':28,'t4':29,'t5':30,'t6':31,
}

def reg(t):
    t = t.strip()
    if t in ABI: return ABI[t]
    m = re.fullmatch(r'x(\d{1,2})', t)
    if m and 0 <= int(m.group(1)) <= 31: return int(m.group(1))
    raise ValueError(f"非法寄存器: {t!r}")

def val(t):
    return int(t.strip(), 0)

def resolve(t, labels):
    t = t.strip()
    return labels[t] if t in labels else int(t, 0)

def memop(s):
    m = re.fullmatch(r'\s*(-?(?:0x[0-9a-fA-F]+|\d+))\(\s*([A-Za-z0-9]+)\s*\)\s*', s)
    if not m: raise ValueError(f"非法内存操作数: {s!r} (应形如 8(sp))")
    return int(m.group(1), 0), reg(m.group(2))

# ---- 指令格式编码 ----
def R(op,f3,f7,rd,rs1,rs2): return (f7<<25)|(rs2<<20)|(rs1<<15)|(f3<<12)|(rd<<7)|op
def I(op,f3,rd,rs1,im):     im&=0xfff; return (im<<20)|(rs1<<15)|(f3<<12)|(rd<<7)|op
def S(op,f3,rs1,rs2,im):
    im&=0xfff
    return (((im>>5)&0x7f)<<25)|(rs2<<20)|(rs1<<15)|(f3<<12)|((im&0x1f)<<7)|op
def B(op,f3,rs1,rs2,im):
    im&=0x1fff
    return (((im>>12)&1)<<31)|(((im>>5)&0x3f)<<25)|(rs2<<20)|(rs1<<15)|(f3<<12)\
           |(((im>>1)&0xf)<<8)|(((im>>11)&1)<<7)|op
def U(op,rd,im):            return ((im&0xfffff)<<12)|(rd<<7)|op
def J(op,rd,im):
    im&=0x1fffff
    return (((im>>20)&1)<<31)|(((im>>12)&0xff)<<12)|(((im>>11)&1)<<20)\
           |(((im>>1)&0x3ff)<<21)|(rd<<7)|op

RREG  = {'add':(0,0x00),'sub':(0,0x20),'sll':(1,0),'slt':(2,0),'sltu':(3,0),
         'xor':(4,0),'srl':(5,0),'sra':(5,0x20),'or':(6,0),'and':(7,0)}
IARITH= {'addi':0,'slti':2,'sltiu':3,'xori':4,'ori':6,'andi':7}
SHIMM = {'slli':(1,0x00),'srli':(5,0x00),'srai':(5,0x20)}
LOAD  = {'lb':0,'lh':1,'lw':2,'lbu':4,'lhu':5}
STORE = {'sb':0,'sh':1,'sw':2}
BR    = {'beq':0,'bne':1,'blt':4,'bge':5,'bltu':6,'bgeu':7}

def expand(mnem, ops):
    """伪指令展开为真实指令列表。"""
    if mnem=='nop':  return [('addi',['x0','x0','0'])]
    if mnem=='mv':   return [('addi',[ops[0],ops[1],'0'])]
    if mnem=='j':    return [('jal',['x0',ops[0]])]
    if mnem=='jr':   return [('jalr',['x0',ops[0],'0'])]
    if mnem=='ret':  return [('jalr',['x0','x1','0'])]
    if mnem=='beqz': return [('beq',[ops[0],'x0',ops[1]])]
    if mnem=='bnez': return [('bne',[ops[0],'x0',ops[1]])]
    if mnem=='li':
        v = int(ops[1],0)
        if -2048 <= v <= 2047:
            return [('addi',[ops[0],'x0',str(v)])]
        lo = v & 0xfff; hi = (v>>12)&0xfffff
        if lo & 0x800: hi=(hi+1)&0xfffff; lo-=0x1000
        return [('lui',[ops[0],str(hi)]),('addi',[ops[0],ops[0],str(lo)])]
    return [(mnem,ops)]

def encode(mnem, ops, addr, labels):
    if mnem in RREG:
        f3,f7 = RREG[mnem]; return R(0x33,f3,f7,reg(ops[0]),reg(ops[1]),reg(ops[2]))
    if mnem in IARITH:
        return I(0x13,IARITH[mnem],reg(ops[0]),reg(ops[1]),val(ops[2]))
    if mnem in SHIMM:
        f3,f7 = SHIMM[mnem]; return I(0x13,f3,reg(ops[0]),reg(ops[1]),(f7<<5)|(val(ops[2])&0x1f))
    if mnem in LOAD:
        off,base = memop(ops[1]); return I(0x03,LOAD[mnem],reg(ops[0]),base,off)
    if mnem in STORE:
        off,base = memop(ops[1]); return S(0x23,STORE[mnem],base,reg(ops[0]),off)
    if mnem in BR:
        return B(0x63,BR[mnem],reg(ops[0]),reg(ops[1]),resolve(ops[2],labels)-addr)
    if mnem=='jal':
        return J(0x6f,reg(ops[0]),resolve(ops[1],labels)-addr)
    if mnem=='jalr':
        return I(0x67,0,reg(ops[0]),reg(ops[1]),val(ops[2]))
    if mnem=='lui':   return U(0x37,reg(ops[0]),val(ops[1]))
    if mnem=='auipc': return U(0x17,reg(ops[0]),val(ops[1]))
    raise ValueError(f"未知指令: {mnem} {ops}")

def parse(path):
    items, labels, addr = [], {}, 0
    for raw in open(path):
        line = raw.split('#')[0].split('//')[0].strip()
        while True:
            m = re.match(r'^([A-Za-z_]\w*):\s*(.*)$', line)
            if not m: break
            labels[m.group(1)] = addr
            line = m.group(2).strip()
        if not line: continue
        parts = line.split(None,1)
        mnem = parts[0].lower()
        if mnem.startswith('.'): continue            # 跳过汇编指示符
        rest = parts[1].strip() if len(parts)>1 else ''
        ops = [o.strip() for o in rest.split(',')] if rest else []
        for m2,o2 in expand(mnem, ops):
            items.append((m2,o2,addr)); addr += 4
    return items, labels

def main():
    if len(sys.argv) != 3:
        print("用法: python3 asm.py <input.s> <output.hex>"); sys.exit(1)
    items, labels = parse(sys.argv[1])
    with open(sys.argv[2],'w') as f:
        for mnem,ops,addr in items:
            w = encode(mnem,ops,addr,labels) & 0xffffffff
            f.write(f"{w:08x}\n")
    print(f"汇编完成: {len(items)} 条指令 -> {sys.argv[2]}")
    if labels: print("标签:", {k:v for k,v in labels.items()})

if __name__ == '__main__':
    main()
