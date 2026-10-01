"""Synthetic screenshots for the redaction probe (privacy review F2). Every number here is invented.
Usage: python3 make_images.py <out_dir>   (needs Pillow)"""
from PIL import Image, ImageDraw, ImageFont
import os
import sys
OUT = sys.argv[1] if len(sys.argv) > 1 else "img"
os.makedirs(OUT, exist_ok=True)
ZH = "/System/Library/Fonts/Hiragino Sans GB.ttc"
EN = "/System/Library/Fonts/Helvetica.ttc"

def font(size, zh=True):
    return ImageFont.truetype(ZH if zh else EN, size)

def canvas(w=1200, h=400, bg=(255, 255, 255)):
    im = Image.new("RGB", (w, h), bg)
    return im, ImageDraw.Draw(im)

def save(im, name):
    im.save(os.path.join(OUT, name + ".png"))

# 1 control
im, d = canvas(); d.text((40, 60), "王师傅手机 13812345678 周五来装", font=font(44), fill=(0, 0, 0))
d.text((40, 200), "尾款 1,280 元，周五下午三点", font=font(44), fill=(0, 0, 0)); save(im, "01_control")
# 2 rotated 90
save(im.rotate(90, expand=True, fillcolor=(255, 255, 255)), "02_rot90")
# 3 rotated 180
save(im.rotate(180, expand=True, fillcolor=(255, 255, 255)), "03_rot180")
# 4 rotated 20 (photo of paper)
save(im.rotate(20, expand=True, fillcolor=(255, 255, 255)), "04_rot20")
# 5 tall long screenshot (chat app 长截图): 1170 x 14000, number line at 38 px
im, d = canvas(1170, 14000)
for y in range(80, 14000, 160):
    d.text((60, y), "今天的会议纪要第 %d 条，大家按计划推进" % (y // 160), font=font(38), fill=(60, 60, 60))
d.rectangle((40, 7000, 1130, 7120), fill=(255, 255, 255))
d.text((60, 7030), "王师傅手机 13812345678", font=font(38), fill=(0, 0, 0)); save(im, "05_long_screenshot")
# 6 id-card number in 18 boxes (paper form)
im, d = canvas(1400, 300); d.text((30, 40), "身份证号码", font=font(40), fill=(0, 0, 0))
digits = "11010519491231002X"
for i, ch in enumerate(digits):
    x = 30 + i * 70; d.rectangle((x, 140, x + 60, 220), outline=(0, 0, 0), width=3)
    d.text((x + 16, 150), ch, font=font(48, zh=False), fill=(0, 0, 0))
save(im, "06_id_boxes")
# 7 phone with dots / middle dots
im, d = canvas(); d.text((40, 60), "联系电话 138·1234·5678", font=font(44), fill=(0, 0, 0))
d.text((40, 200), "备用 138.8765.4321", font=font(44), fill=(0, 0, 0)); save(im, "07_phone_dots")
# 8 split across columns: label cell / value cells in a table row
im, d = canvas(1400, 300)
for x0, txt in ((30, "手机"), (330, "138"), (630, "1234"), (930, "5678")):
    d.rectangle((x0, 100, x0 + 280, 200), outline=(0, 0, 0), width=2); d.text((x0 + 40, 120), txt, font=font(48), fill=(0, 0, 0))
save(im, "08_table_cells")
# 9 low contrast
im, d = canvas(bg=(235, 235, 235)); d.text((40, 60), "验证码 482913 五分钟内有效", font=font(44), fill=(205, 205, 205)); save(im, "09_low_contrast")
# 10 vertical Chinese text column
im, d = canvas(300, 1400)
col ="手机13812345678"
for i, ch in enumerate(col):
    d.text((120, 40 + i * 80), ch, font=font(56), fill=(0, 0, 0))
save(im, "10_vertical")
# 11 small text (12 px) in a 1200 wide screenshot
im, d = canvas(1200, 300); d.text((40, 60), "王师傅手机 13812345678 周五来装", font=font(12), fill=(0, 0, 0)); save(im, "11_tiny_12px")
# 12 bank card number wrapped with an indent that does not overlap
im, d = canvas(1200, 400); d.text((600, 60), "卡号 6222 0212", font=font(44), fill=(0, 0, 0))
d.text((40, 130), "3456 7894 请尽快转账", font=font(44), fill=(0, 0, 0)); save(im, "12_card_wrap_no_overlap")
# 13 OTP phrased number-first (mask rule gap, as seen in a screenshot)
im, d = canvas(); d.text((40, 60), "【招商银行】739146（动态验证码）请勿泄露", font=font(40), fill=(0, 0, 0)); save(im, "13_otp_number_first")
print("ok")
