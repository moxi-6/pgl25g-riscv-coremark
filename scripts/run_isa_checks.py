"""Offline RV32I differential checks; project stop policy is not privileged ISA compliance."""
import argparse
import hashlib
import json
import random
import shutil
import subprocess
from pathlib import Path

MASK=0xFFFFFFFF
def signed(x,bits=32):
    return (x & ((1 << (bits-1))-1)) - (x & (1 << (bits-1)))
def imm(n,rs,f3,rd,op=0x13):
    return ((n&0xFFF)<<20)|(rs<<15)|(f3<<12)|(rd<<7)|op
def reg(f7,rs2,rs1,f3,rd):
    return (f7<<25)|(rs2<<20)|(rs1<<15)|(f3<<12)|(rd<<7)|0x33
def store(n,rs2,rs1,f3):
    return ((n&0xFE0)<<20)|(rs2<<20)|(rs1<<15)|(f3<<12)|((n&31)<<7)|0x23
def branch(n,rs2,rs1,f3):
    return (((n>>12)&1)<<31)|(((n>>5)&63)<<25)|(rs2<<20)|(rs1<<15)|(f3<<12)|(((n>>1)&15)<<8)|(((n>>11)&1)<<7)|0x63
def jump(n,rd):
    return (((n>>20)&1)<<31)|(((n>>1)&1023)<<21)|(((n>>11)&1)<<20)|(((n>>12)&255)<<12)|(rd<<7)|0x6F


def bit_operation(op,f7,f3,rs2,a,b,immediate):
    def rotate(n):
        n &= 31
        return ((a>>n)|(a<<(32-n)))&MASK
    if op==0x33:
        if f7==0x10 and f3 in (2,4,6): return f'SH{f3//2}ADD',(a<<(f3//2))+b
        if f7==0x20 and f3 in (4,6,7):
            return {4:('XNOR',~(a^b)),6:('ORN',a|~b),7:('ANDN',a&~b)}[f3]
        if f7==5 and f3 in (4,5,6,7):
            aa,bb=(signed(a),signed(b)) if f3 in (4,6) else (a,b)
            return {4:'MIN',5:'MINU',6:'MAX',7:'MAXU'}[f3],(min(aa,bb) if f3<6 else max(aa,bb))
        if f7==0x30 and f3 in (1,5): return ('ROL',rotate(-b)) if f3==1 else ('ROR',rotate(b))
        if f7==4 and f3==4 and rs2==0: return 'ZEXT.H',a&0xffff
    if op==0x13:
        if f3==1:
            if immediate==0x600: return 'CLZ',32-a.bit_length()
            if immediate==0x601: return 'CTZ',((a&-a).bit_length()-1) if a else 32
            if immediate==0x602: return 'CPOP',a.bit_count()
            if immediate==0x604: return 'SEXT.B',signed(a,8)
            if immediate==0x605: return 'SEXT.H',signed(a,16)
        if f3==5:
            if f7==0x30: return 'RORI',rotate(rs2)
            if immediate==0x698: return 'REV8',int.from_bytes(a.to_bytes(4,'little'),'big')
            if immediate==0x287: return 'ORC.B',sum(255<<(8*i) for i in range(4) if (a>>(8*i))&255)
    return None


def model(program,initial,zmmul=False,bitmanip=False):
    """Independent decode and architectural state transitions, no RTL imports."""
    regs=[0]*32; memory=bytearray(initial); pc=0; trace=[]; covered=set(); reads=writes=0
    trap=False
    for _ in range(20000):
        ins=program[pc//4] if pc%4==0 and 0<=pc//4<len(program) else 0
        op=ins&127; rd=(ins>>7)&31; f3=(ins>>12)&7; rs1=(ins>>15)&31; rs2=(ins>>20)&31; f7=ins>>25
        a,b=regs[rs1],regs[rs2]; value=0; write=False; target=(pc+4)&MASK; fault=False; name=''
        i=signed(ins>>20,12)
        if ins==0x00100073:
            covered.add('EBREAK'); break
        if op in (0x37,0x17):
            name='LUI' if op==0x37 else 'AUIPC'; value=(ins&0xFFFFF000)+(pc if op==0x17 else 0); write=True
        elif op==0x6F:
            offset=signed(((ins>>31)<<20)|(((ins>>12)&255)<<12)|(((ins>>20)&1)<<11)|(((ins>>21)&1023)<<1),21)
            name='JAL'; value=pc+4; write=True; target=(pc+offset)&MASK
        elif op==0x67 and f3==0:
            name='JALR'; value=pc+4; write=True; target=(a+i)&0xFFFFFFFE
        elif op==0x63 and f3 in (0,1,4,5,6,7):
            offset=signed(((ins>>31)<<12)|(((ins>>7)&1)<<11)|(((ins>>25)&63)<<5)|(((ins>>8)&15)<<1),13)
            conditions={0:a==b,1:a!=b,4:signed(a)<signed(b),5:signed(a)>=signed(b),6:a<b,7:a>=b}
            name={0:'BEQ',1:'BNE',4:'BLT',5:'BGE',6:'BLTU',7:'BGEU'}[f3]
            if conditions[f3]: target=(pc+offset)&MASK
        elif op in (3,0x23):
            offset=i if op==3 else signed(((ins>>25)<<5)|((ins>>7)&31),12)
            address=(a+offset)&MASK
            sizes={0:1,1:2,2:4,4:1,5:2} if op==3 else {0:1,1:2,2:4}
            size=sizes.get(f3,0)
            if not size or address%size or address+size>len(memory): fault=True
            elif op==3:
                name={0:'LB',1:'LH',2:'LW',4:'LBU',5:'LHU'}[f3]
                value=int.from_bytes(memory[address:address+size],'little',signed=f3<4); write=True; reads+=1
            else:
                name={0:'SB',1:'SH',2:'SW'}[f3]
                memory[address:address+size]=(b&((1<<(8*size))-1)).to_bytes(size,'little'); writes+=1
        elif op in (0x13,0x33):
            rhs=i&MASK if op==0x13 else b; sh=rhs&31; write=True
            bit_result=bit_operation(op,f7,f3,rs2,a,b,ins>>20) if bitmanip else None
            if bit_result is not None:
                name,value=bit_result
            elif zmmul and op==0x33 and f7==1 and f3<4:
                name=('MUL','MULH','MULHSU','MULHU')[f3]
                left=signed(a) if f3 in (1,2) else a
                right=signed(b) if f3==1 else b
                value=left*right
                if f3: value >>= 32
            elif f3==0 and (op==0x13 or f7 in (0,32)):
                subtract=op==0x33 and f7==32
                value=a-rhs if subtract else a+rhs; name='SUB' if subtract else ('ADDI' if op==0x13 else 'ADD')
            elif f3 in (1,5) and (f7==0 or (f3==5 and f7==32)):
                if f3==1: value=a<<sh; name='SLL'
                elif f7==32: value=signed(a)>>sh; name='SRA'
                else: value=a>>sh; name='SRL'
                if op==0x13: name+='I'
            elif f3 in (2,3,4,6,7) and (op==0x13 or f7==0):
                value={2:int(signed(a)<signed(rhs)),3:int(a<rhs),4:a^rhs,6:a|rhs,7:a&rhs}[f3]
                name={2:'SLT',3:'SLTU',4:'XOR',6:'OR',7:'AND'}[f3]
                if op==0x13: name={'SLT':'SLTI','SLTU':'SLTIU'}.get(name,name+'I')
            else: fault=True
        elif op==0x0F and f3==0:
            name='FENCE'
        else:
            fault=True
        if target%4: fault=True
        if fault:
            covered.add('ECALL(trap-stop)' if ins==0x73 else 'fault-stop'); trap=True; break
        covered.add(name); value&=MASK; write=write and rd!=0
        trace.append((pc,ins,int(write),rd,value))
        if write: regs[rd]=value
        regs[0]=0; pc=target
    else:
        raise AssertionError('Reference program did not terminate')
    return trace,memory,trap,reads,writes,covered


def prologue():
    return [imm(256,0,0,1),imm(-1,0,0,2),imm(32,0,0,3),0x80000237,imm(-1,4,0,5),imm(1,0,0,6)]


def directed():
    p=prologue()+[0x123453B7,0x00000417,imm(123,0,0,0)]
    for f3 in (0,2,3,4,6,7):
        for n in (-2048,-1,0,2047): p.append(imm(n,4,f3,10+f3))
    for f3,f7 in ((1,0),(5,0),(5,32)):
        for sh in (0,1,31): p.append(imm((f7<<5)|sh,4,f3,18))
    for f3,f7 in ((0,0),(0,32),(1,0),(2,0),(3,0),(4,0),(5,0),(5,32),(6,0),(7,0)):
        for rs in (2,3,5): p.append(reg(f7,rs,4,f3,19))
    for offset in range(4):
        p.extend([imm(offset,1,0,20,3),imm(offset,1,4,21,3)])
    for offset in (0,2): p.extend([imm(offset,1,1,20,3),imm(offset,1,5,21,3)])
    p.append(imm(0,1,2,20,3))
    for offset in range(4): p.append(store(offset,2,1,0))
    for offset in (0,2): p.append(store(offset,5,1,1))
    p.extend([store(4,4,1,2),imm(0,1,2,20,3),imm(4,1,2,21,3)])
    cases=((0,2,2),(1,2,4),(4,4,5),(5,5,4),(6,5,4),(7,4,5))
    for index,(f3,left,right) in enumerate(cases):
        p.extend([branch(8,right,left,f3),store(128+index,2,1,0)])
        # Invert each condition and verify the fall-through store commits.
        other={0:1,1:0,4:5,5:4,6:7,7:6}[f3]
        p.extend([branch(8,right,left,other),store(144+index,5,1,0)])
    p.extend([imm(7,0,0,22),imm(-1,22,0,22),branch(-4,0,22,1)])
    p.extend([jump(12,23),store(200,2,1,0),0])
    target=(len(p)+4)*4
    p.extend([imm(target|1,0,0,24),imm(0,24,0,25,0x67),store(201,2,1,0),0])
    p.extend([branch(2,2,2,1),0x0FF0000F,0x00100073])
    return p


def random_program(seed):
    rng=random.Random(seed); p=prologue()
    for dest in range(7,32):
        value=rng.getrandbits(32); upper=((value+0x800)>>12)&0xFFFFF
        p.extend([(upper<<12)|(dest<<7)|0x37,imm(signed(value&0xFFF,12),dest,0,dest)])
    for _ in range(400):
        kind=rng.randrange(7); dest=rng.choice([0]+list(range(2,32))); a=rng.randrange(32); b=rng.randrange(32)
        if kind==0:
            f3,f7=rng.choice([(0,0),(0,32),(1,0),(2,0),(3,0),(4,0),(5,0),(5,32),(6,0),(7,0)])
            p.append(reg(f7,b,a,f3,dest))
        elif kind==1: p.append(imm(rng.randrange(-2048,2048),a,rng.choice([0,2,3,4,6,7]),dest))
        elif kind==2:
            f3,f7=rng.choice([(1,0),(5,0),(5,32)]); p.append(imm((f7<<5)|rng.randrange(32),a,f3,dest))
        elif kind in (3,4):
            f3=rng.choice([0,1,2,4,5] if kind==3 else [0,1,2]); size={0:1,1:2,2:4,4:1,5:2}[f3]
            offset=rng.randrange(-128//size,128//size)*size
            p.append(imm(offset,1,f3,dest,3) if kind==3 else store(offset,b,1,f3))
        elif kind==5: p.append(branch(8,b,a,rng.choice([0,1,4,5,6,7])))
        else: p.append(jump(8,dest))
    p.append(0x00100073)
    return p


def dump_words(path,words,width=8):
    path.write_text(''.join(f'{x:0{width}x}\n' for x in words),encoding='ascii')


def multiply_program(seed):
    rng=random.Random(seed)
    edges=(0,1,2,0x7fffffff,0x80000000,0xffffffff,0x80000001,0xffff,0x10000)
    pairs=[(a,b) for a in edges for b in edges]
    pairs += [(rng.getrandbits(32),rng.getrandbits(32)) for _ in range(150)]
    p=prologue()
    for index,(a,b) in enumerate(pairs):
        for rd,value in ((8,a),(9,b)):
            p += [((((value+0x800)>>12)&0xfffff)<<12)|(rd<<7)|0x37,
                  imm(signed(value&0xfff,12),rd,0,rd)]
        for f3 in range(4):
            p += [reg(1,9,8,f3,10),imm(1,10,0,11)]
        # Multiply dependencies, aliases, x0, load-use and store-data.
        p += [reg(1,9,8,index%4,8),reg(1,8,9,(index+1)%4,9),
              reg(1,9,8,0,0),store(0,9,1,2),imm(0,1,2,12,3),reg(1,9,12,1,12),
              branch(8,8,8,0),reg(1,9,8,0,13)]
    p.append(0x00100073)
    return p


def bit_program():
    rng=random.Random(20261104)
    values=[0,1,0xffffffff,0x80000000,0x7fffffff,0x800080,0x01000100,0x8000]
    values += [1<<i for i in range(32)] + [rng.getrandbits(32) for _ in range(100)]
    p=prologue()
    for a in values:
        b=rng.getrandbits(32)
        for rd,v in ((8,a),(9,b)):
            p += [((((v+0x800)>>12)&0xfffff)<<12)|(rd<<7)|0x37,imm(signed(v&0xfff,12),rd,0,rd)]
        for f7,f3 in ((0x10,2),(0x10,4),(0x10,6),(0x20,4),(0x20,6),(0x20,7),
                       (5,4),(5,5),(5,6),(5,7),(0x30,1),(0x30,5)):
            p += [reg(f7,9,8,f3,10),imm(1,10,0,11)]
        p += [reg(4,0,8,4,10)]
        for value,f3 in ((0x600,1),(0x601,1),(0x602,1),(0x604,1),(0x605,1),
                         (0x698,5),(0x287,5),(0x600,5),(0x61f,5)):
            p += [imm(value,8,f3,10),imm(1,10,0,11)]
        p += [reg(0x10,9,8,2,8),reg(0x30,8,8,5,9),reg(0x20,8,9,7,0)]
    p.append(0x00100073)
    return p


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output',type=Path)
    parser.add_argument('--zmmul',action='store_true')
    parser.add_argument('--bitmanip',action='store_true')
    parser.add_argument('--dual',action='store_true')
    parser.add_argument('--mul-cycles',type=int,choices=(2,3),default=3)
    parser.add_argument('--decode-pipeline',type=int,choices=(0,1),default=1)
    args=parser.parse_args()
    root=Path(__file__).resolve().parents[1]; out=args.output or root/'build/isa_checks'
    out.mkdir(parents=True,exist_ok=True)
    local=root.parent/'tools/iverilog/bin'
    cc=str(local/'iverilog.exe') if (local/'iverilog.exe').exists() else shutil.which('iverilog')
    vvp=str(local/'vvp.exe') if (local/'vvp.exe').exists() else shutil.which('vvp')
    sources=[root/'rtl/core'/f for f in ('rv32i_pkg.sv','rv32i_alu.sv','rv32i_imm_gen.sv','rv32i_regfile.sv','rv32i_decoder.sv','rv32i_core_3stage.sv')]+[root/'sim/tb_isa_diff.sv']
    binary=out/'tb_isa_diff.vvp'
    compile_result=subprocess.run([cc,'-g2012','-s','tb_isa_diff','-o',str(binary),
        f'-Ptb_isa_diff.ZMMUL_ENABLE={int(args.zmmul)}',f'-Ptb_isa_diff.PIPELINE_DECODE={args.decode_pipeline}',
        f'-Ptb_isa_diff.BITMANIP_ENABLE={int(args.bitmanip)}',
        f'-Ptb_isa_diff.DUAL_ISSUE={int(args.dual)}',
        f'-Ptb_isa_diff.MUL_CYCLES={args.mul_cycles}',
        *map(str,sources)],capture_output=True,text=True)
    (out/'compile.log').write_text(compile_result.stdout+compile_result.stderr,encoding='utf-8')
    if compile_result.returncode: raise RuntimeError('ISA test compilation failed; inspect compile.log')
    cases={'directed':directed()}
    # Control in the younger slot: same-packet operand forwarding, trained
    # taken-to-not-taken transitions, link values and redirected side effects.
    cases['pair_control'] = prologue() + [
        imm(17,0,0,22), imm(0,0,0,23),
        imm(-1,22,0,22), branch(-4,0,22,1),
        imm(9,0,0,23), branch(8,23,23,0),
        store(200,2,1,0), imm(11,0,0,24),
        imm(4,24,0,24), jump(8,25),
        store(201,2,1,0), imm(0,25,0,26),
        imm(88,0,0,27), imm(0,27,0,28,0x67),
        store(202,2,1,0), store(203,2,1,0),
        store(204,26,1,2), store(208,28,1,2), 0x00100073]
    if args.bitmanip: cases['bitmanip']=bit_program()
    if args.zmmul:
        for seed in (42,20261104): cases[f'multiply_{seed}']=multiply_program(seed)
    for seed in (1,7,42,2026,20261028,0xC0FFEE): cases[f'random_{seed}']=random_program(seed)
    faults={'illegal':0xFFFFFFFF,'ecall':0x00000073,'load_half':imm(1,1,1,2,3),
            'load_word':imm(2,1,2,2,3),'store_half':store(1,2,1,1),'store_word':store(2,2,1,2),
            'jump_align':jump(2,2),'jalr_align':imm(2,1,0,2,0x67),'illegal_shift':imm(0x20,4,1,2)}
    for f3 in range(4,8): faults[f'divrem_{f3}']=reg(1,2,4,f3,5)
    faults.update({'reserved_zext':reg(4,1,4,4,5),'rv64_rev8':imm(0x6b8,4,5,5),
                   'reserved_count':imm(0x603,4,1,5),'reserved_shadd':reg(0x10,2,4,3,5)})
    if not args.zmmul:
        for f3 in range(4): faults[f'mul_disabled_{f3}']=reg(1,2,4,f3,5)
    for name,ins in faults.items():
        cases['fault_'+name]=prologue()+[ins,store(220,2,1,0),0x00100073]
        cases['pair_fault_'+name]=prologue()+[imm(19,0,0,30),ins,store(220,2,1,0),0x00100073]
    coverage=set(); results=[]
    initial=bytes((i*73+128)&255 for i in range(1024))
    for name,program in cases.items():
        case=out/name; case.mkdir(exist_ok=True)
        assert len(program)<=8192
        program=program+[0x00100073]*(8192-len(program))
        trace,final,trap,reads,writes,covered=model(program,initial,args.zmmul,args.bitmanip); coverage|=covered
        dump_words(case/'program.hex',program)
        dump_words(case/'initial_ram.hex',[int.from_bytes(initial[i:i+4],'little') for i in range(0,1024,4)])
        dump_words(case/'final_ram.hex',[int.from_bytes(final[i:i+4],'little') for i in range(0,1024,4)])
        dump_words(case/'config.hex',[len(trace),int(trap),reads,writes])
        dump_words(case/'trace.hex',[(pc<<96)|(ins<<64)|(((we<<5)|rd)<<32)|value for pc,ins,we,rd,value in trace],32)
        for mode in range(3):
            # Keep Verilog $readmemh paths ASCII even in a Chinese workspace.
            run=subprocess.run([vvp,str(binary.resolve()),'+case_dir=.',f'+latency_mode={mode}'],cwd=case,capture_output=True,text=True,timeout=60)
            log=run.stdout+run.stderr; (case/f'mode_{mode}.log').write_text(log,encoding='utf-8')
            if run.returncode or '[PASS] isa_diff' not in log: raise RuntimeError(f'{name} mode={mode} failed: {log[-1500:]}')
            results.append({'case':name,'mode':mode,'commits':len(trace),'loads':reads,'stores':writes,'trap':trap})
        print(f'[PASS] isa_case {name} modes=3 commits={len(trace)}')
    guard=subprocess.run([vvp,str(binary.resolve()),'+case_dir=.','+inject_mismatch=1'],cwd=out/'directed',capture_output=True,text=True,timeout=60)
    (out/'mismatch_guard.log').write_text(guard.stdout+guard.stderr,encoding='utf-8')
    if guard.returncode==0: raise RuntimeError('Injected commit mismatch was not rejected')
    required=set('LUI AUIPC JAL JALR BEQ BNE BLT BGE BLTU BGEU LB LH LW LBU LHU SB SH SW ADDI SLTI SLTIU XORI ORI ANDI SLLI SRLI SRAI ADD SUB SLL SLT SLTU XOR SRL SRA OR AND FENCE EBREAK'.split())
    if args.zmmul: required.update(('MUL','MULH','MULHSU','MULHU'))
    if args.bitmanip: required.update('SH1ADD SH2ADD SH3ADD ANDN ORN XNOR CLZ CTZ CPOP MIN MAX MINU MAXU SEXT.B SEXT.H ZEXT.H ROL ROR RORI ORC.B REV8'.split())
    if required-coverage: raise RuntimeError(f'Missing instruction coverage: {required-coverage}')
    summary={'status':'PASS','cases':len(cases),'latency_modes':3,'runs':len(results),'checked_commits':sum(r['commits'] for r in results),
             'instruction_behaviors':sorted(coverage),'required_normal_and_stop_behaviors':len(required),
             'commit_mismatch_guard':True,'zmmul':args.zmmul,'bitmanip':args.bitmanip,'dual':args.dual,'decode_pipeline':args.decode_pipeline,
             'mul_cycles':args.mul_cycles,
             'results':results,'source_sha256':{str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sources},
             'scope':'Directed and seeded random differential simulation against project execution/stop policy. Not an official RISC-V architectural certification or hardware proof.'}
    (out/'summary.json').write_text(json.dumps(summary,indent=2),encoding='utf-8')
    print(f'[PASS] isa_checks runs={len(results)} checked_commits={summary["checked_commits"]} behaviors={len(coverage)}')


if __name__=='__main__':
    main()
