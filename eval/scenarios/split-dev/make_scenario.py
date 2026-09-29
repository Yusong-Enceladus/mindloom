#!/usr/bin/env python3
"""Build eval/scenarios/split-dev/scenario.json: an invented two-week scenario for item-split tuning.

Domain (unrelated to every other scenario): 沈棠 produces a small indie game at 纸鸢游戏 while running
her family life. Most items are long and cover several matters at once — stand-up transcripts in the
Tencent Meeting / Feishu / Zoom export formats, long dictations on the road, brainstorm and to-do dumps,
pasted group chats — so they must be cut into parts and each part filed into its own event. Some long
items cover only one matter (they must stay whole), a hard decoy shares its composer with the game's
music, and a few notices are noise. Every name, company, number and date is fictional.

Gold: items[].events (item-level, multi-label) and items[].segments [{event_id, quote}] where the quote
is the exact rendered text of that part (scored by eval/score.py segment Link F1). Chit-chat parts have
no segment. Run:  python3 eval/scenarios/split-dev/make_scenario.py  (rewrites scenario.json).
"""

from __future__ import annotations

import json
import uuid
from pathlib import Path

NS = uuid.UUID("3c5e1f0a-8d2b-4b7e-9a41-51d7e0c0de01")
HERE = Path(__file__).resolve().parent


def uid(name: str) -> str:
    return str(uuid.uuid5(NS, name)).upper()


PEOPLE = [
    {"person_id": "p_owner", "display_name": "沈棠", "is_owner": True, "role": "纸鸢游戏制作人（本人）",
     "aliases": ["我", "棠姐", "沈制作"],
     "voice": {"mac_person_id": uid("voice-owner"), "user_label": "我", "tts_hint": "female-30s-brisk"}},
    {"person_id": "p_lu", "display_name": "陆骁", "role": "主程"},
    {"person_id": "p_xu", "display_name": "许蔓", "role": "策划"},
    {"person_id": "p_he", "display_name": "何一苇", "role": "美术（兼职）"},
    {"person_id": "p_zheng", "display_name": "郑毅", "role": "远帆互娱发行经理"},
    {"person_id": "p_lin", "display_name": "林听雨", "role": "作曲"},
    {"person_id": "p_gao", "display_name": "高岚", "role": "成都独立游戏展对接人"},
    {"person_id": "p_zhou", "display_name": "周凛", "role": "樱桥翻译项目经理"},
    {"person_id": "p_wang", "display_name": "王建平", "role": "办公室房东"},
    {"person_id": "p_xiaoman", "display_name": "小满", "role": "本人的大学室友（婚礼）"},
    {"person_id": "p_liang", "display_name": "梁晨", "role": "主美候选人"},
    {"person_id": "p_teacher", "display_name": "孟老师", "role": "幼儿园班主任"},
]
NAME_TO_ID = {p["display_name"]: p["person_id"] for p in PEOPLE}

EVENTS = [
    {"event_id": "ev_demo", "kind": "main", "title": "Steam 新品节试玩版",
     "summary": "试玩版修崩溃、Steam Deck 帧率、提交构建和发行方评审。"},
    {"event_id": "ev_pub", "kind": "main", "title": "远帆互娱发行合同",
     "summary": "分成比例、预付款分期、PC 独占期和合同签署。"},
    {"event_id": "ev_music", "kind": "main", "title": "游戏配乐外包",
     "summary": "林听雨为游戏写三首曲子，含费用、风格和交付时间。"},
    {"event_id": "ev_song", "kind": "decoy", "difficulty": "hard", "decoy_of": "ev_music", "title": "小满婚礼歌",
     "summary": "同一位作曲林听雨在帮本人的室友小满改编婚礼歌，和游戏配乐无关。"},
    {"event_id": "ev_hire", "kind": "main", "title": "招聘主美",
     "summary": "主美候选人作品集、面试、offer 和入职。"},
    {"event_id": "ev_booth", "kind": "main", "title": "成都独立游戏展展位",
     "summary": "展位大小、费用、物料、布展、差旅。"},
    {"event_id": "ev_office", "kind": "main", "title": "办公室续租",
     "summary": "房东涨租、看新办公室、最终续租。"},
    {"event_id": "ev_loc", "kind": "main", "title": "日文本地化",
     "summary": "樱桥翻译的报价、术语表、交付和费用分担。"},
    {"event_id": "ev_kid", "kind": "main", "title": "苗苗插班入园",
     "summary": "女儿幼儿园插班材料、家长会和入园。"},
    {"event_id": "ev_dentist", "kind": "main", "title": "牙科复诊",
     "summary": "本人的牙科复诊改期和结果。"},
    {"event_id": "ev_copyright", "kind": "main", "title": "软件著作权登记",
     "summary": "第二周开始办的软著登记材料。"},
    {"event_id": "ev_noise", "kind": "noise", "title": "通知与闲聊", "summary": "物业通知、快递、广告。"},
]

# ---------------------------------------------------------------------------------------------------
# Items. parts: [(event_id or None, content)]; content by format:
#   tencent / feishu / zoom : [(speaker, utterance), ...]
#   chat                    : [(sender, message), ...]         (pasted WeChat text, "名：内容")
#   dictation               : "sentences..."                  (one paragraph)
#   doc                     : ["line", ...]                   (a note; rendered as "- line")
# ---------------------------------------------------------------------------------------------------

ITEMS = [
    # ===== week 1 =====
    dict(ref="m01", t="2026-10-12T09:30:00+08:00", fmt="tencent", app="腾讯会议", parts=[
        (None, [("沈棠", "早，人齐了吗？许蔓你那边麦克风有点炸。"), ("许蔓", "好了好了，刚换了耳机。")]),
        ("ev_demo", [("陆骁", "试玩版这周最大的问题是第二章存档，读档的时候有概率直接崩，我复现了三次，应该是存档版本号没对上。"),
                     ("沈棠", "这个必须周五前修掉，新品节的构建下周一就要锁。Steam Deck 上帧率现在多少？"),
                     ("陆骁", "森林那关只有四十帧左右，我打算先把粒子数量减半试试。")]),
        ("ev_hire", [("许蔓", "主美那边这周收到三份作品集，我挑了两份比较对路的，一个偏写实，一个偏手绘。"),
                     ("沈棠", "手绘那个我想先聊，约周三下午两点面试吧，你把作品集链接发群里。")]),
        ("ev_booth", [("沈棠", "还有成都展，高岚昨天发了展位图，三乘三和三乘六两个方案，周四之前要回她。"),
                      ("陆骁", "三乘三放两台试玩机就满了，我倾向三乘六。")]),
        (None, [("沈棠", "行，那先这样，散会。")]),
    ]),
    dict(ref="m02", t="2026-10-12T11:10:00+08:00", fmt="dictation", app="备忘录", parts=[
        ("ev_office", "记一下，房东王建平早上打电话，说十二月起办公室房租要涨百分之八，从一万二涨到一万二千九百六，让我这个月底前答复续不续。"),
        ("ev_kid", "苗苗插班的事，幼儿园说周五前要交户口本复印件和疫苗接种证明，我得找时间去打印。"),
        ("ev_dentist", "还有牙科那边，陈医生的复诊从周三挪到周四下午四点，别忘了。"),
    ]),
    dict(ref="s01", t="2026-10-12T13:05:00+08:00", fmt="chat", app="微信", parts=[
        ("ev_pub", [("郑毅", "沈制作，合同第二版发你邮箱了，分成按七三，预付款三十万，你们先看条款。"),
                    ("沈棠", "收到，下午电话细聊。")]),
    ]),
    dict(ref="m03", t="2026-10-12T15:00:00+08:00", fmt="feishu", app="飞书", parts=[
        (None, [("郑毅", "喂，能听到吧？我这边在高铁上，信号不太好。")]),
        ("ev_pub", [("沈棠", "能听到。合同我们看了，七三的分成我们想争取到七五二五，毕竟宣发我们自己也出一部分。"),
                    ("郑毅", "七五二五我得回去跟老板汇报，不过预付款三十万可以拆成两期，签约一期，上线一期。")]),
        ("ev_loc", [("郑毅", "另外日文版你们找谁翻？我们合作过樱桥翻译，按字算零点九元一个字，质量还行。"),
                    ("沈棠", "那你把樱桥的联系人推给我，我让许蔓先导出文本算字数。")]),
        ("ev_demo", [("郑毅", "还有一个，我们内部要在二十号之前拿到试玩版构建做评审。"),
                     ("沈棠", "没问题，构建周一锁版，锁完就发你。")]),
    ]),
    dict(ref="m04", t="2026-10-12T17:40:00+08:00", fmt="doc", app="备忘录", filename="展会和试玩版的脑暴.txt", parts=[
        ("ev_booth", ["展位中间立一只两米高的纸鸢装置，灯从里面打出来，远处就能看到",
                      "试玩机位放四台，两台 PC 两台 Steam Deck，排队区放游戏原画的明信片"]),
        ("ev_demo", ["试玩版开头加一段三十秒的开场动画，现在一进去就是菜单，太干",
                     "试玩结束页加一个愿望单按钮，直接跳 Steam 商店页"]),
        ("ev_music", ["展会现场循环的背景音乐请林听雨从主题曲里剪一版，别用临时曲"]),
        (None, ["周末记得买咖啡豆"]),
    ]),
    dict(ref="n01", t="2026-10-12T19:00:00+08:00", fmt="chat", app="微信", parts=[
        (None, [("物业管家", "各位业主，本周四上午九点到十二点小区停水检修，请提前储水。")]),
    ]),
    dict(ref="m05", t="2026-10-13T10:00:00+08:00", fmt="zoom", app="Zoom", parts=[
        (None, [("林听雨", "Hi，我这边画面卡了一下，你听得到吗？"), ("沈棠", "听得到，我们开始吧。")]),
        ("ev_music", [("沈棠", "配乐这边一共三首，主题曲、森林关和最后的 Boss 战，你报价是每首八千对吧？"),
                      ("林听雨", "对，三首两万四，十一月五号前全部交，二十号先给你主题曲的小样。"),
                      ("沈棠", "可以，风格上我想要一点竹笛，但别太古风。")]),
        ("ev_song", [("林听雨", "对了，小满那首婚礼歌我改编好一半了，她说婚礼是十一月一号，你帮我问问她副歌要不要加和声？"),
                     ("沈棠", "我晚上问她，那首歌的小样你单独发我，别跟游戏的文件混在一起。")]),
        (None, [("林听雨", "好嘞，那先这样，拜拜。")]),
    ]),
    dict(ref="m06", t="2026-10-13T12:30:00+08:00", fmt="chat", app="微信", parts=[
        ("ev_demo", [("陆骁", "存档崩溃找到了，是旧存档没带版本号，我加了兼容，今晚打新包。")]),
        ("ev_hire", [("何一苇", "主美候选人那两份作品集我也看了，手绘那个叫梁晨的构图很好，写实那个偏商业。"),
                     ("许蔓", "梁晨的面试我约好了，周三下午两点，线上。")]),
        ("ev_booth", [("高岚", "沈老师，三乘六的展位费是一万二，三乘三是七千，周四前定下来我好排位置。")]),
    ]),
    dict(ref="s02", t="2026-10-13T14:10:00+08:00", fmt="dictation", app="备忘录", parts=[
        ("ev_dentist", "牙科诊所刚来电话，陈医生周四下午临时有手术，复诊再往后挪到周四五点，我说可以。"),
    ]),
    dict(ref="m07", t="2026-10-13T16:00:00+08:00", fmt="tencent", app="腾讯会议", parts=[
        ("ev_hire", [("何一苇", "美术周会先说招聘，梁晨周三面完如果合适，我希望她能下个月就来，森林关的场景我一个人画不过来。"),
                     ("沈棠", "面完我们当天就定，薪资上限我这边是三万。")]),
        ("ev_demo", [("何一苇", "试玩版的 UI 图标我重画了一半，背包和地图两个图标周四给陆骁。"),
                     ("沈棠", "图标周四一定要进包，锁版以后就不能动了。")]),
        ("ev_office", [("何一苇", "还有个事，听说房东要涨租，我们是不是考虑换个有自然光的地方？现在这间下午太暗了。"),
                       ("沈棠", "我也在想，创意园那边有一间一百二十平的，我这周去看看。")]),
        (None, [("何一苇", "那我先去吃饭了，今天食堂有红烧肉。")]),
    ]),
    dict(ref="m08", t="2026-10-13T21:40:00+08:00", fmt="dictation", app="备忘录", parts=[
        ("ev_kid", "睡前记一下，孟老师说周四晚上七点开家长会，插班的孩子家长必须到，还要带苗苗的入园体检表。"),
        ("ev_song", "小满那边我问了，她说婚礼歌副歌要加和声，让林听雨周末把小样发她听。"),
        ("ev_office", "明天中午去创意园看那间一百二十平的办公室，中介说月租一万五，但是有大窗户。"),
    ]),
    dict(ref="m09", t="2026-10-14T09:30:00+08:00", fmt="tencent", app="腾讯会议", parts=[
        ("ev_demo", [("陆骁", "好消息，Steam Deck 上森林关粒子减半以后能到五十五帧了，存档兼容也合进去了。"),
                     ("沈棠", "好，那周五提交 Steam 审核的构建就用今晚这个包。")]),
        ("ev_loc", [("许蔓", "日文本地化的文本我导出来了，一共四万两千字，已经发给樱桥的周凛。"),
                    ("沈棠", "按零点九算就是三万七千八，让他们给个正式报价单。")]),
        ("ev_booth", [("沈棠", "成都展我决定要三乘六了，高岚要我们周四前给高清 logo 和主视觉。"),
                      ("何一苇", "主视觉我今天出，logo 有现成的矢量文件。")]),
        ("ev_hire", [("许蔓", "下午两点梁晨面试，面试官是我、何一苇和棠姐。")]),
    ]),
    dict(ref="s03", t="2026-10-14T14:00:00+08:00", fmt="feishu", app="飞书", parts=[
        ("ev_hire", [("许蔓", "我们开始吧，梁晨你先简单介绍一下自己。"),
                     ("梁晨", "我之前在一家做卡牌游戏的公司做了五年原画，最后两年带三个人的小组，比较擅长手绘的场景。"),
                     ("何一苇", "你作品集里那张雨夜集市的图，光影是怎么处理的？"),
                     ("梁晨", "先铺冷色的环境光，再用暖色点出摊位的灯，最后统一加一层雾。"),
                     ("沈棠", "我们团队很小，主美也要自己画很多图，你能接受吗？期望薪资是多少？"),
                     ("梁晨", "可以接受，我更想做自己喜欢的项目，期望是两万八。"),
                     ("许蔓", "好的，今天就到这，我们内部商量后尽快回复你。")]),
    ]),
    dict(ref="m10", t="2026-10-14T16:30:00+08:00", fmt="chat", app="微信", parts=[
        ("ev_pub", [("郑毅", "老板那边同意七五二五，但条件是 PC 版给我们十二个月独占。"),
                    ("沈棠", "独占十二个月我们内部要商量，主机版不受影响吧？"),
                    ("郑毅", "主机不受影响，只限 PC 平台。")]),
        ("ev_loc", [("郑毅", "樱桥那边报价出来了吗？"),
                    ("沈棠", "周凛刚发了，总价三万八，交付十一月十号。")]),
        ("ev_demo", [("郑毅", "试玩版评审我们定在二十一号上午，你们派个人线上讲一下。")]),
    ]),
    dict(ref="m11", t="2026-10-14T19:10:00+08:00", fmt="dictation", app="备忘录", parts=[
        ("ev_office", "创意园那间看了，采光是好，但离地铁要走十五分钟，而且月租一万五太贵；晚上王建平松口了，说涨百分之五也行，就是一万二千六，要签一年。"),
        ("ev_dentist", "牙科确认了，明天周四下午五点，陈医生那边。"),
        ("ev_kid", "苗苗的户口本复印件和疫苗证明都打印好了，放在玄关的文件袋里，明早交给幼儿园。"),
        (None, "今天真的好累，晚饭随便吃点吧。"),
    ]),
    dict(ref="m12", t="2026-10-15T10:00:00+08:00", fmt="zoom", app="Zoom", parts=[
        (None, [("周凛", "沈老师早上好，我这边共享一下屏幕。")]),
        ("ev_loc", [("周凛", "日文版我们按三万八报价，十一月十号交付，前提是你们先给一份术语表，人名地名要统一。"),
                    ("沈棠", "术语表许蔓下周一给你，里面大概两百个词。"),
                    ("周凛", "好的，付款是签约付一半，交付验收后付一半。")]),
        ("ev_demo", [("周凛", "试玩版要不要先做日文？"),
                     ("沈棠", "试玩版只做日文 UI，剧情文本等正式版，你们先翻 UI 那三百来条。")]),
        ("ev_booth", [("周凛", "成都展要是有日本媒体来，我们可以帮你们做一张日文的宣传单。"),
                      ("沈棠", "好主意，宣传单做一页 A5 就行，展会前一周给我。")]),
    ]),
    dict(ref="m13", t="2026-10-15T11:30:00+08:00", fmt="doc", app="备忘录", filename="周四待办.txt", parts=[
        ("ev_demo", ["提交构建前过一遍检查单：崩溃日志清零、成就关闭、存档路径改成正式版的",
                     "确认何一苇的两个新图标已经进包"]),
        ("ev_booth", ["把 logo 矢量文件和主视觉发给高岚", "易拉宝做两个，一个放入口一个放试玩区"]),
        ("ev_hire", ["给梁晨发 offer，月薪两万八，试用期三个月"]),
        ("ev_music", ["催林听雨二十号的主题曲小样，顺便把森林关的参考曲发给她"]),
        ("ev_kid", ["晚上七点家长会，带苗苗的体检表"]),
    ]),
    dict(ref="n02", t="2026-10-15T12:10:00+08:00", fmt="chat", app="微信", parts=[
        (None, [("丰巢", "您的快递已存入小区东门 3 号柜，取件码 482913，请于 24 小时内取件。")]),
    ]),
    dict(ref="m14", t="2026-10-15T15:00:00+08:00", fmt="tencent", app="腾讯会议", parts=[
        (None, [("郑毅", "我拉了我们法务小周进来，大家先互相认识一下。")]),
        ("ev_pub", [("郑毅", "合同这版改了三处：分成七五二五，PC 独占十二个月，预付款三十万分两期，签约和上线各十五万。"),
                    ("沈棠", "独占我们同意，但要加一条：如果上线后六个月销量没到五万份，独占自动取消。"),
                    ("郑毅", "这个我可以去争取，法务会把条款写进补充协议。")]),
        ("ev_loc", [("郑毅", "日文本地化的钱我们发行方可以承担一半，就是一万九。"),
                    ("沈棠", "那太好了，樱桥的合同我们来签，你们把一半打给我们。")]),
        ("ev_demo", [("郑毅", "二十一号上午十点的评审会议邀请我已经发了。"),
                     ("沈棠", "收到，陆骁来讲技术，我讲玩法。")]),
    ]),
    dict(ref="s04", t="2026-10-15T18:20:00+08:00", fmt="dictation", app="备忘录", parts=[
        ("ev_dentist", "牙看完了，陈医生说补的那颗没问题，下次复查半年以后，四月份再约。"),
    ]),
    dict(ref="m15", t="2026-10-15T21:00:00+08:00", fmt="dictation", app="备忘录", parts=[
        ("ev_kid", "家长会结束了，孟老师说苗苗的材料齐了，下周一就可以入园，要准备一套换洗衣服和一个水杯。"),
        ("ev_song", "路上听了林听雨发来的婚礼歌小样，副歌有点长，我让她删掉八个小节再发给小满。"),
        ("ev_music", "游戏配乐第一首的方向我也跟她定了，竹笛加合成器，节奏要比婚礼歌快很多。"),
    ]),
    dict(ref="m16", t="2026-10-16T09:30:00+08:00", fmt="tencent", app="腾讯会议", parts=[
        (None, [("沈棠", "周五了，大家精神点，五分钟快速过一下。")]),
        ("ev_demo", [("陆骁", "构建昨晚已经提交 Steam 审核了，一般两到三个工作日出结果。"),
                     ("沈棠", "审核过了第一时间发郑毅那边。")]),
        ("ev_booth", [("何一苇", "易拉宝的设计稿下周一出，纸鸢装置我找了一家做灯箱的工厂，报价四千五。")]),
        ("ev_hire", [("许蔓", "梁晨接了 offer，十一月二号入职，电脑我这周订。")]),
        ("ev_office", [("沈棠", "办公室我决定不搬了，跟王建平续租一年，涨百分之五，下周签合同。")]),
    ]),
    dict(ref="m17", t="2026-10-16T13:00:00+08:00", fmt="feishu", app="飞书", parts=[
        ("ev_booth", [("高岚", "沈老师，你们的展位号定了，B 区十七号，三乘六，十一月六号下午布展。"),
                      ("沈棠", "好的，电源要几个插座？我们有四台试玩机和一个灯箱。"),
                      ("高岚", "标配两个十六安的插座，不够的话可以加购，一个三百。"),
                      ("沈棠", "那再加两个。我们去四个人，展馆附近的酒店你们有协议价吗？"),
                      ("高岚", "有，协议价三百八一晚，我把预订链接发你。")]),
    ]),
    dict(ref="m18", t="2026-10-16T18:30:00+08:00", fmt="dictation", app="备忘录", parts=[
        (None, "这周复盘一下。"),
        ("ev_demo", "试玩版构建已经交了 Steam 审核，二十一号给远帆做评审，这周最大的风险是审核被打回。"),
        ("ev_pub", "合同基本谈妥，七五二五加十二个月 PC 独占，销量不到五万份自动取消独占的条款还在等他们法务。"),
        ("ev_music", "配乐三首两万四，二十号出主题曲小样。"),
        ("ev_office", "办公室续租一年，每月一万二千六，下周二签。"),
    ]),
    dict(ref="m19", t="2026-10-17T10:20:00+08:00", fmt="chat", app="微信", parts=[
        ("ev_kid", [("孩子爸", "苗苗周一入园的东西我列了：换洗衣服两套、水杯、午睡小被子。"),
                    ("沈棠", "被子要写名字，我今晚绣上。")]),
        ("ev_song", [("小满", "棠棠，林听雨改的婚礼歌我听了，太好听了，谢谢你介绍！"),
                     ("沈棠", "喜欢就好，婚礼那天我一定到。")]),
    ]),
    dict(ref="n03", t="2026-10-17T15:00:00+08:00", fmt="chat", app="微信", parts=[
        (None, [("健身房", "会员日特惠：私教课买十送二，本周日截止，详询前台。")]),
    ]),
    # ===== week 2 =====
    dict(ref="m20", t="2026-10-19T09:30:00+08:00", fmt="tencent", app="腾讯会议", parts=[
        (None, [("沈棠", "周一站会，大家周末休息得怎么样？"), ("陆骁", "还行，打了两天羽毛球。")]),
        ("ev_demo", [("陆骁", "Steam 审核周六就过了，商店页的试玩按钮已经能看到，新品节是二十六号开始。"),
                     ("沈棠", "那评审前我们再跑一遍完整流程，别在郑毅他们面前崩。")]),
        ("ev_loc", [("许蔓", "术语表整理好了，两百一十个词，今天发给周凛。")]),
        ("ev_copyright", [("许蔓", "还有，发行合同附件里要求我们提供软件著作权登记证书，我们还没办。"),
                          ("沈棠", "那这周就开始办，你查一下要什么材料，源代码要打印前后各三十页吧？"),
                          ("陆骁", "对，源代码我来整理。")]),
    ]),
    dict(ref="m21", t="2026-10-19T11:00:00+08:00", fmt="dictation", app="备忘录", parts=[
        ("ev_kid", "今天苗苗第一天入园，早上哭了五分钟就好了，孟老师下午发了照片，在搭积木。"),
        ("ev_office", "王建平说续租合同周二上午十点来办公室签，我要准备营业执照复印件和押金两万五。"),
        ("ev_booth", "何一苇的易拉宝设计稿出来了，我觉得主标题字太小，展会上远看不清，让她放大一倍。"),
    ]),
    dict(ref="s05", t="2026-10-19T14:30:00+08:00", fmt="chat", app="微信", parts=[
        ("ev_copyright", [("许蔓", "软著登记材料我查了：申请表、源程序前后各三十页、用户手册、营业执照复印件，线上提交，官方审查大概三十个工作日。"),
                          ("沈棠", "加急要多少钱？"),
                          ("许蔓", "代理说加急十五个工作日，费用两千八。")]),
    ]),
    dict(ref="m22", t="2026-10-19T16:00:00+08:00", fmt="zoom", app="Zoom", parts=[
        ("ev_music", [("林听雨", "主题曲小样我提前传到网盘了，竹笛在前奏，副歌进合成器，你听听。"),
                      ("沈棠", "我听了，前奏特别好，副歌的鼓稍微吵，能不能收一点？"),
                      ("林听雨", "可以，我周三给你改好的版本，森林关那首我这周开始写。")]),
        ("ev_song", [("林听雨", "小满的婚礼歌定稿了，她说想在婚礼上现场唱，我还得帮她做一版伴奏。"),
                     ("沈棠", "伴奏的钱让她直接跟你结，我就不参与了。")]),
    ]),
    dict(ref="m23", t="2026-10-20T09:30:00+08:00", fmt="feishu", app="飞书", parts=[
        ("ev_demo", [("陆骁", "明天评审的演示流程我排好了：开场动画、第一章、森林关、Boss 战，一共二十分钟。"),
                     ("沈棠", "Boss 战那段容易卡，演示用的存档提前准备好。")]),
        ("ev_copyright", [("陆骁", "软著的源代码我整理了，前后各三十页，每页五十行，已经去掉了注释里的内部地址。"),
                          ("许蔓", "用户手册我写好了，今天找代理提交，走加急。")]),
        ("ev_hire", [("许蔓", "梁晨入职的电脑和数位板都订好了，十一月二号前到。")]),
    ]),
    dict(ref="m24", t="2026-10-20T12:00:00+08:00", fmt="chat", app="微信", parts=[
        ("ev_office", [("王建平", "沈总，明天上午十点我过来签合同，押金两万五直接转我卡上就行。"),
                       ("沈棠", "王叔，合同签完押金当面转，我们需要收据。")]),
        ("ev_booth", [("高岚", "沈老师，酒店协议价的预订链接发你了，十一月五号到八号，记得十月底前订。"),
                      ("沈棠", "好的，四个人订两间双床。")]),
    ]),
    dict(ref="m25", t="2026-10-20T21:30:00+08:00", fmt="dictation", app="备忘录", parts=[
        ("ev_pub", "郑毅晚上发消息说，销量不到五万份自动取消独占那条，他们法务改成了八个月内不到五万份，我觉得可以接受。"),
        ("ev_loc", "周凛说术语表收到了，有十二个词要跟我们确认读音，主要是地名。"),
        ("ev_kid", "苗苗说幼儿园午饭有她不爱吃的胡萝卜，明天跟孟老师说一下。"),
        (None, "明天评审，早点睡。"),
    ]),
    dict(ref="m26", t="2026-10-21T10:00:00+08:00", fmt="tencent", app="腾讯会议", parts=[
        (None, [("郑毅", "大家早，我们这边有发行、市场和测试三个同事。")]),
        ("ev_demo", [("陆骁", "我先演示第一章和森林关，Steam Deck 上现在稳定五十五帧。"),
                     ("郑毅", "测试同事反馈，开场动画不能跳过，新品节玩家会很烦，建议加跳过按钮。"),
                     ("沈棠", "好，跳过按钮这周加上，二十四号前出新包。")]),
        ("ev_pub", [("郑毅", "合同补充协议今天发你，八个月五万份的条款写进去了，你们签完寄回，我们打第一笔十五万。")]),
        ("ev_booth", [("郑毅", "成都展我们市场部也会去，你们展位上能不能留一面墙贴我们的发行 logo？"),
                      ("沈棠", "可以，展位背板右下角留给你们，尺寸我让何一苇发你。")]),
    ]),
    dict(ref="m27", t="2026-10-21T14:00:00+08:00", fmt="dictation", app="备忘录", parts=[
        ("ev_office", "上午王建平来签了续租合同，一年，每月一万二千六，押金两万五当面转了，收据拍照存好了。"),
        ("ev_demo", "评审整体反馈不错，唯一的硬伤是开场动画不能跳过，陆骁说两天能加完。"),
        ("ev_copyright", "软著代理说材料齐了，加急十五个工作日，预计十一月十号左右下证。"),
    ]),
    dict(ref="m28", t="2026-10-21T17:30:00+08:00", fmt="chat", app="微信", parts=[
        ("ev_loc", [("周凛", "沈老师，十二个地名的读音表我发你邮箱了，麻烦周四前确认。"),
                    ("沈棠", "好，我让许蔓对一下。")]),
        ("ev_hire", [("梁晨", "沈老师您好，入职前需要我先看看项目的美术规范吗？"),
                     ("沈棠", "需要，我让何一苇把规范文档和森林关的原画发你。")]),
        ("ev_kid", [("孟老师", "苗苗妈妈，下周三幼儿园有亲子运动会，家长需要穿运动鞋，早上八点半到。")]),
    ]),
    dict(ref="s06", t="2026-10-21T19:00:00+08:00", fmt="tencent", app="腾讯会议", parts=[
        ("ev_booth", [("何一苇", "展位背板我改了三版，这版把远帆的 logo 放在右下角，六十乘四十厘米。"),
                      ("沈棠", "纸鸢装置的位置往左挪一点，别挡住试玩机。"),
                      ("何一苇", "好，那入口的易拉宝就往外移五十厘米。"),
                      ("沈棠", "工厂那边灯箱四千五确定了吗？"),
                      ("何一苇", "确定了，十一月三号发货到成都展馆。")]),
    ]),
    dict(ref="m29", t="2026-10-22T09:30:00+08:00", fmt="tencent", app="腾讯会议", parts=[
        ("ev_demo", [("陆骁", "开场动画的跳过按钮加好了，顺便修了两个评审时发现的小 bug，新包今晚打。")]),
        ("ev_loc", [("许蔓", "十二个地名的读音我对完了，有三个用训读，已经回给周凛。")]),
        ("ev_music", [("沈棠", "林听雨把主题曲改好的版本发过来了，鼓收了，我觉得可以定稿了。"),
                      ("陆骁", "定稿的话我这周就替换进试玩版，新品节用正式主题曲。")]),
        ("ev_copyright", [("许蔓", "软著代理说申请表里的开发完成日期要写具体到日，我们填的是九月三十号。")]),
        (None, [("沈棠", "好，中午一起点外卖吧，我请。")]),
    ]),
    dict(ref="m30", t="2026-10-22T13:00:00+08:00", fmt="doc", app="备忘录", filename="新品节上线前清单.txt", parts=[
        ("ev_demo", ["二十四号前出带跳过按钮和正式主题曲的新包", "二十五号晚上最后确认商店页截图和预告片",
                     "新品节期间每天看一次崩溃报告"]),
        ("ev_booth", ["酒店十月底前订，两间双床，十一月五号到八号", "加购两个插座，每个三百"]),
        ("ev_pub", ["补充协议签字盖章后寄回远帆，收到后催第一笔十五万预付款"]),
        ("ev_kid", ["下周三亲子运动会，八点半到，穿运动鞋"]),
    ]),
    dict(ref="n04", t="2026-10-22T16:00:00+08:00", fmt="chat", app="微信", parts=[
        (None, [("银行", "尊敬的客户，您的信用卡本期账单已出，最后还款日为十一月八日。")]),
    ]),
    dict(ref="m31", t="2026-10-22T20:00:00+08:00", fmt="dictation", app="备忘录", parts=[
        ("ev_pub", "补充协议签好字了，明天一早用顺丰寄给郑毅，单号记得发他。"),
        ("ev_song", "小满打电话说婚礼伴奏林听雨做好了，她想请我在婚礼上当伴娘，我答应了，十一月一号要早上六点到化妆间。"),
        ("ev_booth", "成都的酒店订好了，两间双床，四个晚上，一共三千零四十。"),
    ]),
    dict(ref="m32", t="2026-10-23T09:30:00+08:00", fmt="feishu", app="飞书", parts=[
        ("ev_demo", [("陆骁", "新包昨晚上传了，带跳过按钮和正式主题曲，Steam 那边显示已经生效。"),
                     ("沈棠", "好，今天下午我在 Steam Deck 上完整玩一遍。")]),
        ("ev_hire", [("何一苇", "美术规范文档我整理好发给梁晨了，她说入职前先熟悉森林关的原画。")]),
        ("ev_loc", [("许蔓", "周凛说 UI 的三百条日文已经翻完了，下周可以进试玩版。"),
                    ("沈棠", "试玩版已经锁了，日文 UI 放到正式版吧。")]),
        ("ev_copyright", [("许蔓", "软著的开发完成日期改成九月三十号重新提交了，代理说不影响加急。")]),
    ]),
    dict(ref="m33", t="2026-10-23T12:30:00+08:00", fmt="chat", app="微信", parts=[
        ("ev_pub", [("郑毅", "补充协议收到了，财务今天走第一笔十五万的流程，下周到账。"),
                    ("沈棠", "谢谢郑哥，发票我们开好寄过去。")]),
        ("ev_booth", [("郑毅", "对了，我们市场部去成都展的是三个人，到时候在你们展位轮班可以吗？"),
                      ("沈棠", "可以，展位上多两个人帮忙更好。")]),
    ]),
    dict(ref="m34", t="2026-10-23T18:00:00+08:00", fmt="dictation", app="备忘录", parts=[
        (None, "第二周复盘。"),
        ("ev_demo", "试玩版新包已经生效，二十六号新品节开始，我下午在掌机上完整玩了一遍，没崩。"),
        ("ev_pub", "补充协议寄到了，第一笔十五万预付款下周到账。"),
        ("ev_music", "主题曲定稿，森林关那首林听雨这周开始写，十一月五号前三首全部交。"),
        ("ev_copyright", "软著走的加急，预计十一月十号左右下证。"),
        ("ev_booth", "展会的酒店、插座、灯箱都搞定了，还差易拉宝放大字号的终稿。"),
    ]),
    dict(ref="m35", t="2026-10-24T10:00:00+08:00", fmt="chat", app="微信", parts=[
        ("ev_kid", [("孩子爸", "运动会的运动鞋我给苗苗买好了，你的在鞋柜第二层。")]),
        ("ev_song", [("小满", "伴娘服我寄到你公司了，周一应该能到，你试试大小。"),
                     ("沈棠", "收到，不合身我找裁缝改。")]),
        ("ev_office", [("王建平", "沈总，续租合同的收据和发票我放在前台了。")]),
    ]),
    dict(ref="m36", t="2026-10-24T11:30:00+08:00", fmt="doc", app="备忘录", filename="下半年想法.txt", parts=[
        ("ev_music", ["正式版再请林听雨加一首片尾曲，预算控制在一万以内"]),
        ("ev_hire", ["梁晨入职第一周先画森林关的三张场景，周五做一次美术评审"]),
        ("ev_office", ["续租以后把靠窗那面墙刷成浅色，再买两盏落地灯，下午就不暗了"]),
        ("ev_copyright", ["软著下证以后扫描一份放共享盘，发行合同附件要用"]),
        (None, ["想试试每周三下午不开会"]),
    ]),
    dict(ref="m37", t="2026-10-25T09:00:00+08:00", fmt="chat", app="微信", parts=[
        ("ev_demo", [("陆骁", "新品节提前一天的预热页上线了，愿望单一晚上涨了八百。"),
                     ("沈棠", "太好了，截图发群里，周一给郑毅看。")]),
        ("ev_kid", [("孟老师", "苗苗妈妈，运动会改到周四了，周三下雨。")]),
        ("ev_song", [("小满", "伴娘服合身吗？婚礼前一天晚上我们彩排，七点在酒店宴会厅。")]),
    ]),
    dict(ref="m38", t="2026-10-25T20:30:00+08:00", fmt="dictation", app="备忘录", parts=[
        ("ev_song", "伴娘服试了，腰那里有点紧，明天拿去裁缝店放一公分，小满婚礼前一晚七点彩排。"),
        ("ev_kid", "苗苗的运动会改到周四，我那天上午请半天假。"),
        ("ev_loc", "周凛问正式版剧情文本什么时候给，我说十一月第一周，等试玩版新品节结束再定稿。"),
        ("ev_demo", "明天新品节正式开始，早上九点我和陆骁盯一下崩溃报告和评论。"),
    ]),
    dict(ref="m39", t="2026-10-26T09:30:00+08:00", fmt="tencent", app="腾讯会议", parts=[
        (None, [("沈棠", "新品节第一天，大家辛苦了。")]),
        ("ev_demo", [("陆骁", "凌晨到现在一共一千二百人玩了试玩版，崩溃两次，都是老显卡的驱动问题。"),
                     ("沈棠", "老显卡的问题在商店页的已知问题里写一句，别让玩家以为是游戏的锅。")]),
        ("ev_booth", [("何一苇", "易拉宝放大字号的终稿我昨晚发给印刷厂了，十一月三号跟灯箱一起发成都。")]),
        ("ev_pub", [("许蔓", "财务说远帆第一笔十五万到账了，发票已经寄出。")]),
        ("ev_hire", [("许蔓", "梁晨的工位我安排在何一苇旁边，门禁卡周五办好。")]),
    ]),
    dict(ref="m40", t="2026-10-26T17:30:00+08:00", fmt="feishu", app="飞书", parts=[
        ("ev_loc", [("周凛", "沈老师，正式版剧情文本如果十一月第一周给，我们十二月十号能交，比原计划晚一个月，报价不变。"),
                    ("沈棠", "可以，那合同交付日期改到十二月十号。")]),
        ("ev_booth", [("周凛", "成都展的日文宣传单我们排好版了，A5 单页，印刷文件今天发你。"),
                      ("沈棠", "收到，我让何一苇跟易拉宝一起送去印刷厂。")]),
        (None, [("周凛", "那先这样，新品节加油！")]),
    ]),
    dict(ref="s07", t="2026-10-24T15:00:00+08:00", fmt="zoom", app="Zoom", parts=[
        ("ev_music", [("林听雨", "森林关的曲子我写了一个开头，用了口哨和木琴，感觉有点森林的轻快。"),
                      ("沈棠", "口哨很好，但森林关后半段有追逐，节奏要能加快。"),
                      ("林听雨", "那我做两段，前半段轻快，后半段加鼓，追逐的时候切过去。"),
                      ("沈棠", "可以，这样游戏里做动态切换也方便，陆骁那边能接。"),
                      ("林听雨", "好，下周三给你完整版。")]),
    ]),
]

FORMAT_KIND = {"tencent": "text", "feishu": "text", "zoom": "text", "chat": "text", "dictation": "dictation",
               "doc": "document"}


def _hms(sec: int) -> str:
    return f"{sec // 3600:02d}:{sec % 3600 // 60:02d}:{sec % 60:02d}"


def render(item: dict) -> tuple[str, list[tuple[str, str]], list[str]]:
    """(text as sent, [(event_id, quote)], speakers named) for one item."""
    fmt = item["fmt"]
    chunks: list[tuple[str | None, str]] = []
    speakers: list[str] = []
    clock = 3
    for event, content in item["parts"]:
        if fmt in ("tencent", "feishu", "zoom"):
            lines = []
            for who, said in content:
                speakers.append(who)
                if fmt == "tencent":
                    lines.append(f"{who}({_hms(clock)}):\n{said}\n")
                elif fmt == "feishu":
                    lines.append(f"{who} {_hms(clock)}\n{said}\n")
                else:
                    lines.append(f"[{_hms(clock)}] {who}: {said}")
                clock += 25 + len(said) // 2
            chunks.append((event, ("\n" if fmt != "zoom" else "\n").join(lines).rstrip("\n")))
        elif fmt == "chat":
            speakers += [who for who, _ in content]
            chunks.append((event, "\n".join(f"{who}：{said}" for who, said in content)))
        elif fmt == "dictation":
            chunks.append((event, content))
        else:
            chunks.append((event, "\n".join(f"- {line}" for line in content)))
    sep = {"tencent": "\n\n", "feishu": "\n\n", "zoom": "\n", "chat": "\n", "dictation": "", "doc": "\n"}[fmt]
    body = sep.join(c for _, c in chunks)
    text = f"{item['filename']}\n\n{body}" if fmt == "doc" else body
    quotes = [(event, chunk) for event, chunk in chunks if event]
    for _, q in quotes:
        assert text.count(q) == 1, q[:30]
    return body, quotes, speakers


def build() -> dict:
    items = []
    for it in ITEMS:
        body, quotes, speakers = render(it)
        events = list(dict.fromkeys(e for e, _ in quotes)) or ["ev_noise"]
        persons = ["p_owner"] if it["fmt"] == "dictation" else []
        for who in speakers:
            pid = NAME_TO_ID.get(who)
            if pid and pid not in persons:
                persons.append(pid)
        if it["fmt"] in ("tencent", "feishu", "zoom", "chat") and "沈棠" in speakers and "p_owner" not in persons:
            persons.insert(0, "p_owner")
        row = {"item_id": uid(it["ref"]), "ref": it["ref"], "t": it["t"], "kind": FORMAT_KIND[it["fmt"]],
               "source_app": it["app"], "persons": persons, "events": [e for e in events if e != "ev_noise"],
               "text": body}
        if row["events"] == [] and events == ["ev_noise"]:
            row["events"] = ["ev_noise"]
        if it["fmt"] == "doc":
            row["filename"] = it["filename"]
        if it["fmt"] == "dictation":
            row["duration_ms"] = 4000 + 180 * len(body)
        if len(quotes) >= 2:
            row["segments"] = [{"event_id": e, "quote": q} for e, q in quotes]
            row["tags"] = ["multi_matter"]
        elif it["ref"].startswith("s"):
            row["tags"] = ["single_matter_long"] if len(body) >= 150 else ["single_matter"]
        items.append(row)
    week1_last = max((i for i in items if i["t"] < "2026-10-18"), key=lambda i: i["t"])
    return {
        "$schema": "../../schema/scenario.schema.json",
        "scenario_id": "split-dev",
        "version": 1,
        "split": "dev",
        "synthetic": True,
        "locale": "zh-CN",
        "title": "纸鸢游戏的两周（item-split 开发集）",
        "description": "虚构：独立游戏制作人沈棠两周里的站会转写（腾讯会议/飞书/Zoom 导出格式）、路上长口述、脑暴和待办、"
                       "粘贴的群聊，大多一条里说了好几件事（试玩版、发行合同、配乐、招聘、展会、续租、本地化、软著、女儿入园、"
                       "看牙）；同一位作曲还在帮室友改编婚礼歌（难干扰事件）。只用于调 item-split，与其他场景领域无关。"
                       "人物、公司、金额、日期全部为虚构。",
        "owner_person_id": "p_owner",
        "people": PEOPLE,
        "events": EVENTS,
        "items": items,
        "facts": [],
        "checkpoints": [
            {"checkpoint_id": "cp-w1", "after_item_id": week1_last["item_id"], "label": "第一周末", "expected": {}},
            {"checkpoint_id": "cp-w2", "after_item_id": items[-1]["item_id"], "label": "第二周末", "expected": {}},
        ],
    }


def main() -> int:
    scenario = build()
    out = HERE / "scenario.json"
    out.write_text(json.dumps(scenario, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    multi = sum(1 for i in scenario["items"] if len(i.get("segments") or []) >= 2)
    print(f"{out}: {len(scenario['items'])} items, {multi} multi-matter, {len(scenario['events'])} events")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
