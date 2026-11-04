"""Build the independent 16-pixel Chinese mine-game font and RTL labels."""
from pathlib import Path
import json,re
from PIL import Image, ImageDraw, ImageFont
ROOT=Path(__file__).resolve().parents[1]
LABELS=[
'触屏扫雷','关卡 1/8','地图','地雷 00','插旗 00','待开 00','用时000秒','首点安全',
'数字是邻雷数','翻开全部安全格','0左 1右 2下','KEY3短按翻开','长按插旗','触屏点格翻开',
'','', '草原棋盘','边角遗迹','中央峡谷','孤岛回廊','正在排雷','踩雷失败','关卡完成',
'触屏点格插旗','模式：翻开','模式：插旗','重开本关','下一关','全部通关重玩',
'首点周围无雷 右侧可切换插旗','踩雷了！按任意键或右侧按钮重开','过关！按任意键或右侧按钮继续',
'0123456789'
]
chars=list(dict.fromkeys(' '+''.join(LABELS)))
assert len(chars)<=128,len(chars)
ids={ch:i for i,ch in enumerate(chars)}
font=ImageFont.truetype('C:/Windows/Fonts/msyh.ttc',16)
words=[]
for ch in chars:
 im=Image.new('L',(16,16));d=ImageDraw.Draw(im)
 if ch!=' ':
  b=font.getbbox(ch);d.text(((16-b[2]+b[0])//2-b[0],-b[1]),ch,font=font,fill=255)
 for y in range(16):
  v=0
  for x in range(16):v=(v<<1)|(im.getpixel((x,y))>=100)
  words.append(f'{v:04x}')
words+=['0000']*(2048-len(words))
(ROOT/'rtl/periph/mine_font.hex').write_text('\n'.join(words)+'\n',encoding='ascii')
(ROOT/'rtl/periph/mine_font_map.json').write_text(json.dumps({'glyphs':ids,'labels':LABELS},ensure_ascii=False,indent=2),encoding='utf-8')
lines=['    function automatic [6:0] text_id(input integer line,input integer col);','        begin case(line)']
for n,label in enumerate(LABELS):
 lines.append(f'            {n}: case(col)')
 for c,ch in enumerate(label):lines.append(f"                {c}:text_id=7'd{ids[ch]};")
 lines.append('                default:text_id=0; endcase')
lines+=['            default:text_id=0; endcase end','    endfunction',
'    function automatic [6:0] digit_id(input integer n);','        begin case(n)']
for n in range(10):lines.append(f"            {n}:digit_id=7'd{ids[str(n)]};")
lines+=['            default:digit_id=0; endcase end','    endfunction']
p=ROOT/'rtl/periph/lcd_mine_display.sv';s=p.read_text(encoding='utf-8')
s=re.sub(r'    // BEGIN_GENERATED_MINE_FONT.*?    // END_GENERATED_MINE_FONT','    // BEGIN_GENERATED_MINE_FONT\n'+'\n'.join(lines)+'\n    // END_GENERATED_MINE_FONT',s,flags=re.S)
p.write_text(s,encoding='utf-8')
print(f'Generated {len(chars)} mine glyphs')
