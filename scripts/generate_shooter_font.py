"""Generate the local Chinese bitmap font and renderer labels from Windows YaHei."""
from pathlib import Path
import json
from PIL import Image, ImageFont, ImageDraw
root=Path(__file__).resolve().parents[1]
labels=[
    '横版闯关','关卡 0','生命 0','得分 0000','剩余 0','更新周期','00000000','退休指令','00000000',
    '约45帧每秒','清敌后右行','进入绿门','按键开始','游戏进行','闯关成功','生命耗尽',
    '横版射击闯关','按任意按键开始','KEY0左移  KEY1右移','KEY2跳跃  KEY3射击','清除红色敌人后走到右端绿门',
    '闯关成功！按任意键重玩','生命耗尽！按任意键重玩','蓝色是你 红色是敌人','长按射击可以连续发射',
    '0123456789ABCDEF ',
]
chars=list(dict.fromkeys(' '+''.join(labels)))
assert len(chars)<128
ids={ch:i for i,ch in enumerate(chars)}
font=ImageFont.truetype('C:/Windows/Fonts/msyh.ttc',16)
words=[]
for ch in chars:
    im=Image.new('L',(16,16)); d=ImageDraw.Draw(im)
    if ch!=' ':
        bbox=font.getbbox(ch)
        width=bbox[2]-bbox[0]
        d.text(((16-width)//2-bbox[0],-bbox[1]),ch,font=font,fill=255)
    for y in range(16):
        value=0
        for x in range(16): value=(value<<1)|(im.getpixel((x,y))>=100)
        words.append(f'{value:04x}')
words += ['0000']*(2048-len(words))
(root/'rtl/periph/shooter_font.hex').write_text('\n'.join(words)+'\n',encoding='ascii')
(root/'rtl/periph/shooter_font_map.json').write_text(json.dumps(ids,ensure_ascii=False,indent=2),encoding='utf-8')
cases=[]
for line,text in enumerate(labels):
    cases.append(f'            {line}: begin case(col)')
    cases += [f'                {col}:text_id=7\'d{ids[ch]};' for col,ch in enumerate(text)]
    cases.append('                default:text_id=0; endcase end')
func='''    function [6:0] text_id(input [4:0] line,input [5:0] col);
        begin case(line)
'''+ '\n'.join(cases)+'''
            default:text_id=0; endcase end
    endfunction
    function [6:0] digit_id(input [3:0] n);
        begin case(n)
'''+ '\n'.join(f"            {i}:digit_id=7'd{ids[ch]};" for i,ch in enumerate('0123456789ABCDEF'))+'''
            default:digit_id=0; endcase end
    endfunction
'''
template=(root/'rtl/periph/lcd_shooter_display.sv.in').read_text(encoding='utf-8')
(root/'rtl/periph/lcd_shooter_display.sv').write_text(template.replace('// GENERATED_FONT_FUNCTIONS',func),encoding='ascii')
print(f'Generated {len(chars)} glyphs in a 2048x16 synchronous font ROM')
