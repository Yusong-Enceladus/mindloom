# Mindloom 标语

2026-10-06 用户裁决：标语不只一句；中文、英文各一套，引经据典的和直白的（游戏、文学等各种类型）都放进来，按合适的规则轮换显示。本文件记录规则和全部句子。

- 数据（以它为准）：`Packages/MindloomDesign/Sources/MindloomTaglines/Resources/taglines.json`
- 选句逻辑：`MindloomTaglines`（`TaglineRotation`、`TaglineStore`），测试 `MindloomTaglinesTests`
- Mac 界面：`BestASRMemoryUI/Shell/MindloomTaglineViews.swift`（`WelcomeTagline`、`SidebarTagline`、`MindloomTaglineBoard`）

## 1. 两套句子

- 中文 42 句，英文 41 句。类型：经典引文（classic）、已进入公有领域的现代作家（modern-pd）、直白原创（plain）、游戏通用提示的句式（game-idiom）、致敬（homage，只借意象或句式，不用原句）。
- 每句的字段：`id`、`text`、`source`（只有引文有）、`kind`、`counterpart`（另一种语言里对应的那句，两边互相指向）、`moment`（见第 2 节），以及不显示的 `checked`（引文核对原文的地址）和 `inspiration`（原创句的灵感来源）。
- 跟着 App 的界面语言：界面是中文显示中文那套，其他语言显示英文那套（`TaglineLanguage(interfaceLanguage:)`）。V1 的界面只有简体中文（`DictationAppModel` 把界面语言固定为 zh-Hans），所以现在 App 里只会出现中文那套；以后有了英文界面，不用改这里。

## 2. 轮换规则

**每 6 小时换一句，在窗口出现时取，显示期间不换。** 2026-10-06 先定的是一天一句，同一天用户改为每 6 小时一句。

- **四个时段。** 产品时区的一天分成四段：0:00–5:59、6:00–11:59、12:00–17:59、18:00–23:59，每段一句，在 0 点、6 点、12 点、18 点换。不按启动换：Mindloom 常驻菜单栏，一开就是好几天，按启动换几乎看不到变化。
- **什么时候取。** 窗口来到屏幕上的那一刻：打开窗口、从程序坞或别的桌面回来、原来被别的窗口完全挡住后露出来（`WindowShownMonitor`）。窗口一直显示着就不换；到了换句的时刻窗口还开着，新的一句等它下次出现。欢迎窗口在打开时取一次。
- **时段按产品时区算。** 资料库里设置的时区（现在是 Asia/Singapore），不是 Mac 的时区。有夏令时的时区里，时段仍从当地的 0 点、6 点、12 点、18 点开始；调钟那天，从 0 点开始的那段是 5 或 7 小时。
- **每台安装自己的顺序。** 第一次显示时生成一个随机种子，记下这一段为第 0 段。除回访句以外的句子按种子洗牌排成一轮，每段一句：一轮里每句出现一次，全部出现过才重复；下一轮重新洗，不会用上一轮最后一句开头。中文一轮 40 段（10 天），英文一轮 39 段。
- **新装第一句。** 第 0 段显示标为 `first` 的那句：“编织你的史诗。”／“Weave your epic.”。之后它作为日常句参加轮换。
- **早上、晚上、深夜句。** 在每一轮里各占一段，而且只排在对应的时段：早上句排在 6:00–11:59 的某一段，晚上句排在 18:00–23:59 的某一段，深夜句排在 0:00–5:59 的某一段；排到的那一段整段显示它，其余各段由日常句轮流。不会排在一轮的第 0 段。12:00–17:59 没有专门的句子。一天一句时这几句只在对应钟点显示，同一天里会换句；按时段换以后不再需要这个例外。
- **回访。** 距上次显示超过 3 天（按产品时区的日期算，第 4 天起）再打开，那一段显示一句回访句：“好久不见，上次聊到哪了？”或“上回书说到……”（英文：“Long time no see. Where were we?”／“Previously on your epic…”）。下一段回到轮换。
- **存在哪里。** App 偏好里的一个键 `mindloom.taglines.install`，值是一段 JSON（种子、第 0 段、上次显示的那段、回访的那段）。删掉它就和新装一样，从第一句开始。一天一句的版本存下的值读不出来，也从第一句开始（那个版本没有发布过）。不放资料库：这是这台安装看到的顺序，不是资料。
- **句子有增删时。** 按新的句数重新排，不保证接上原来的位置。
- **不按类型错开。** 最初的整理稿提议“尽量不连着出现同一类”（比如前后两句都是引文），没有做；保证的是一轮里不重复、跨轮不连着同一句。

## 3. 显示在哪里

- **欢迎窗口第一屏**（新装第一次打开时）：字标下面，取代原来的“所闻所言，各归其处。”。句子 17/26 pt，平衡断行；引文在下面一行用 12 pt 小字写出处，中文写“——韩愈《进学解》”，英文写“— William Shakespeare, The Tempest”。中文每句都在一行内；英文最长两行。
- **主窗口边栏底部，“设置”上面**：每次打开主窗口都能看到的一处安静位置。12 pt、`ink3` 浅色，宽 192 pt 内平衡断行；引文出处 11 pt。用边栏原本空着的地方，不移动任何一行，首页的排布不变（首页按用户要求先保持现状）。
- **比较过、没有选的地方。** 关于（很少打开）；首页和分组的空状态（有了内容就看不到）；菜单栏菜单（系统菜单里放一句话不是 Mac 的做法，长句会把菜单撑宽）；首页本身（用户要求先不动）。
- **iPhone。** 第一屏的那一行是“按住说话，或从分享菜单发送，内容都会发送到你的 Mac。”，是使用说明，不是标语位置，这次不改。`MindloomTaglines` 放在 Mac 和 iPhone 共用的 `MindloomDesign` 包里，iPhone 以后要用，链接这个产品即可；现在不链接，键盘和分享扩展里也就没有这份数据。
- **截图**（`/Users/Shared/mindloom-demo/v12/shots/taglines/`，亮色和暗色）：检查版 App（`com.bestasr.mindloom.check`，合成演示资料库的新克隆）实拍 `welcome-first-*`（新装第一屏）、`sidebar-first-day-*`（新装第一句时的边栏）、`sidebar-quote-*`（轮到引文时，带出处）；`render/` 是快照测试渲染的其他句子：最长的中文句、英文句和英文引文在欢迎页和边栏里的样子，空资料库的边栏，以及回访时的边栏（`x-sidebar-tagline-return-*`、`x-sidebar-tagline-en-return-*`）。实拍的回访截图显示的是审校撤下的“都还在你放下的地方。”，已移到 `superseded/`，回访的取句机制在那两张里仍然看得到。这些截图是一天一句的版本拍的；改成每 6 小时一句只改了取哪一句，显示的样子不变。`monitor-probe.txt`：窗口隐藏再显示时才取句的探针记录。

## 4. 和界面文字规范的关系

- 标语是品牌文字。`docs/UI-COPY.md` 的“书面、简洁”（§1.3）和不用比喻词的词表（§1.4：织、网、thread 等）不适用于标语：要有直白的，完全文绉绉的也不好；“编织你的史诗”是确定下来的方向之一。比喻只留在品牌里，标语正是品牌。
- 仍然遵守：中文用全角标点和“ ”，不用「」；英文用弯引号和撇号；不写技术词。`MindloomTaglinesTests` 检查标点、长度、出处和对应关系，也检查句子里没有安抚（“都还在”“safe”）和催促（“截止”“deadline”）的词，撤下的 id 不再使用。
- “记忆会改口，原话不会。”里有“不会”：说的是记忆和录音的对比，不是对数据的承诺，保留。
- 上线前请人看一眼：“不久以前，在一间不太远的会议室里……”／“Not long ago, in a meeting room not so far away…”（《星球大战》片头句式的戏仿，没有用原句）。

## 5. 全部句子

### 中文（42 句）

| id | 句子 | 出处 / 灵感 | 类型 | 时机 | 对应 |
|---|---|---|---|---|---|
| zh-01 | 记事者必提其要，纂言者必钩其玄。 | 韩愈《进学解》 | 经典引文 |  |  |
| zh-02 | 左史记言，右史记事。 | 《汉书·艺文志》 | 经典引文 |  |  |
| zh-03 | 若网在纲，有条而不紊。 | 《尚书·盘庚上》 | 经典引文 |  | en-06 |
| zh-04 | 经正而后纬成，理定而后辞畅。 | 刘勰《文心雕龙·情采》 | 经典引文 |  |  |
| zh-05 | 物有本末，事有终始，知所先后。 | 《礼记·大学》 | 经典引文 |  | en-04 |
| zh-06 | 述往事，思来者。 | 司马迁《史记·太史公自序》 | 经典引文 |  | en-02 |
| zh-07 | 善删者字去而意留。 | 刘勰《文心雕龙·镕裁》 | 经典引文 |  | en-03 |
| zh-08 | 我手写我口，古岂能拘牵。 | 黄遵宪《杂感》 | 经典引文 |  | en-07 |
| zh-09 | 唧唧复唧唧，木兰当户织。 | 《木兰诗》 | 经典引文 |  |  |
| zh-10 | 贪多务得，细大不捐。 | 韩愈《进学解》 | 经典引文 |  |  |
| zh-11 | 众里寻他千百度；蓦然回首，那人却在，灯火阑珊处。 | 辛弃疾《青玉案·元夕》 | 经典引文 |  |  |
| zh-13 | 究天人之际，通古今之变，成一家之言。 | 司马迁《报任安书》 | 经典引文 |  | en-09 |
| zh-43 | 嘤其鸣矣，求其友声。 | 《诗经·小雅·伐木》 | 经典引文 |  |  |
| zh-14 | 大胆地说话，勇敢地进行 | 鲁迅《无声的中国》 | 现代（公有领域） |  |  |
| zh-44 | 带露折花，色香自然要好得多 | 鲁迅《朝花夕拾·小引》 | 现代（公有领域） |  |  |
| zh-16 | 编织你的史诗。 | 灵感：用户提出的方向 | 直白 | 新装第一句 | en-15 |
| zh-17 | 你只管开口，其余交给 Mindloom。 | 灵感：柯达 1888 年的广告语 “You press the button, we do the rest.”（只借句式） | 直白 |  | en-16 |
| zh-18 | 史诗，是平常日子攒出来的。 |  | 直白 |  | en-17 |
| zh-19 | 好记性，不如张嘴说。 | 灵感：俗语“好记性不如烂笔头”（改写） | 直白 |  | en-18 |
| zh-20 | 嗯、啊、那个，统统不算。 |  | 直白 |  | en-19 |
| zh-21 | 自言自语，终于有了正当理由。 |  | 直白 |  | en-20 |
| zh-22 | 所有的“回头再说”，都在这里。 |  | 直白 |  | en-21 |
| zh-23 | 一个人的会，也有纪要。 |  | 直白 |  | en-22 |
| zh-24 | 话里有事。 |  | 直白 |  | en-23 |
| zh-25 | 好久不见，上次聊到哪了？ |  | 直白 | 回访 | en-24 |
| zh-45 | 上回书说到…… | 灵感：评书和章回小说接着讲的开场套话 | 直白 | 回访 | en-43 |
| zh-27 | 说着说着，就清楚了。 |  | 直白 |  | en-26 |
| zh-28 | 夜深了，想法还醒着。 |  | 直白 | 深夜 | en-27 |
| zh-29 | 东一句，西一句，也能织成一匹布。 |  | 直白 |  | en-28 |
| zh-30 | 千头万绪，总有头绪。 |  | 直白 |  | en-29 |
| zh-31 | 任务日志已更新。 | 灵感：RPG 通用界面提示，不属于哪一款游戏 | 游戏句式 |  | en-30 |
| zh-32 | 成就解锁：想说的，说出口了。 | 灵感：游戏平台成就弹窗的通用格式 | 游戏句式 |  | en-31 |
| zh-33 | 新同伴加入了队伍。 | 灵感：JRPG 入队提示的通用格式 | 游戏句式 |  | en-32 |
| zh-34 | 每个主角身边，都该有个执笔的人。 | 灵感：《巫师 3》的任务日志由吟游诗人执笔；西幻里为英雄作传的诗人 | 致敬 |  | en-33 |
| zh-35 | 不久以前，在一间不太远的会议室里…… | 灵感：《星球大战》片头字幕（反写） | 致敬 |  | en-34 |
| zh-36 | 你的记忆宫殿，这回有了目录。 | 灵感：《神探夏洛克》的“思维宫殿”；源头是古希腊的记忆宫殿术（公有领域） | 致敬 |  | en-35 |
| zh-37 | 每说一句，都是一个存档点。 | 灵感：《传说之下》（Undertale）的存档点 | 致敬 |  | en-36 |
| zh-38 | 嘿，这回换我来听。 | 灵感：《塞尔达传说：时之笛》里 Navi 的口头禅（反写，不用原句） | 致敬 |  | en-37 |
| zh-39 | 你醒了。今天从哪儿说起？ | 灵感：《上古卷轴 V：天际》开场马车上被叫醒的场景（只借场景） | 致敬 | 早上 | en-38 |
| zh-40 | 来火边坐坐，说说今天。 | 灵感：《黑暗之魂》的篝火 | 致敬 | 晚上 | en-39 |
| zh-41 | 一个名字，连着一串事。 |  | 直白 |  | en-40 |
| zh-42 | 记忆会改口，原话不会。 | 灵感：特德·姜《事实真相，感觉真相》 | 致敬 |  | en-41 |

### 英文（41 句）

| id | 句子 | 出处 / 灵感 | 类型 | 时机 | 对应 |
|---|---|---|---|---|---|
| en-01 | The web of our life is of a mingled yarn, good and ill together. | William Shakespeare, All’s Well That Ends Well | 经典引文 |  |  |
| en-02 | What’s past is prologue. | William Shakespeare, The Tempest | 经典引文 |  | zh-06 |
| en-03 | Take care of the sense, and the sounds will take care of themselves. | Lewis Carroll, Alice’s Adventures in Wonderland | 经典引文 |  | zh-07 |
| en-04 | Begin at the beginning, … and go on till you come to the end: then stop. | Lewis Carroll, Alice’s Adventures in Wonderland | 经典引文 |  | zh-05 |
| en-05 | It’s a poor sort of memory that only works backwards. | Lewis Carroll, Through the Looking-Glass | 经典引文 |  |  |
| en-06 | Let all your things have their places. | Benjamin Franklin, Autobiography | 经典引文 |  | zh-03 |
| en-07 | The pen is the tongue of the mind. | Miguel de Cervantes, Don Quixote (tr. John Ormsby) | 经典引文 |  | zh-08 |
| en-09 | There is properly no history, only biography. | Ralph Waldo Emerson, “History” | 经典引文 |  | zh-13 |
| en-10 | I am a part of all that I have met | Alfred Tennyson, “Ulysses” | 经典引文 |  |  |
| en-11 | Every limit is a beginning as well as an ending. | George Eliot, Middlemarch | 经典引文 |  |  |
| en-12 | Memory, my dear Cecily, is the diary that we all carry about with us. | Oscar Wilde, The Importance of Being Earnest | 经典引文 |  |  |
| en-13 | Stay a little, that we may make an end the sooner. | quoted by Francis Bacon, “Of Dispatch” | 经典引文 |  |  |
| en-14 | And so to bed. | Samuel Pepys, Diary | 经典引文 | 深夜 |  |
| en-42 | The true art of memory is the art of attention. | Samuel Johnson, The Idler, No. 74 | 经典引文 |  |  |
| en-15 | Weave your epic. | 灵感：用户提出的方向 | 直白 | 新装第一句 | zh-16 |
| en-16 | You talk. Mindloom weaves the rest. | 灵感：Kodak’s 1888 slogan “You press the button, we do the rest.” (shape only) | 直白 |  | zh-17 |
| en-17 | Every epic is written one Tuesday at a time. |  | 直白 |  | zh-18 |
| en-18 | Forget the pen. Just say it. |  | 直白 |  | zh-19 |
| en-19 | Ums and uhs not included. |  | 直白 |  | zh-20 |
| en-20 | Finally, a good reason to talk to yourself. |  | 直白 |  | zh-21 |
| en-21 | Every “let’s circle back” ends up here. |  | 直白 |  | zh-22 |
| en-22 | Minutes for a meeting of one. |  | 直白 |  | zh-23 |
| en-23 | Words in. Plans out. |  | 直白 |  | zh-24 |
| en-24 | Long time no see. Where were we? |  | 直白 | 回访 | zh-25 |
| en-43 | Previously on your epic… | 灵感：The TV recap opener “Previously on…” | 直白 | 回访 | zh-45 |
| en-26 | Ramble freely. The point will surface. |  | 直白 |  | zh-27 |
| en-27 | It’s late, and your thoughts are wide awake. |  | 直白 | 深夜 | zh-28 |
| en-28 | Loose ends, woven in. |  | 直白 |  | zh-29 |
| en-29 | So many threads. One clear pattern. |  | 直白 |  | zh-30 |
| en-30 | Quest log updated. | 灵感：RPG 通用界面提示 | 游戏句式 |  | zh-31 |
| en-31 | Achievement unlocked: You said the thing. | 灵感：游戏平台成就弹窗的通用格式 | 游戏句式 |  | zh-32 |
| en-32 | A new companion has joined your party. | 灵感：JRPG 入队提示的通用格式 | 游戏句式 |  | zh-33 |
| en-33 | Every hero needs a chronicler. | 灵感：The Witcher 3 journal written by the bard Dandelion | 致敬 |  | zh-34 |
| en-34 | Not long ago, in a meeting room not so far away… | 灵感：Star Wars opening crawl (parody, original wording) | 致敬 |  | zh-35 |
| en-35 | Your mind palace, now with an index. | 灵感：Sherlock (BBC) mind palace; the classical method of loci | 致敬 |  | zh-36 |
| en-36 | Every sentence is a save point. | 灵感：Undertale save points | 致敬 |  | zh-37 |
| en-37 | Hey—this time, I’ll listen. | 灵感：Navi, The Legend of Zelda: Ocarina of Time (inverted, not the original line) | 致敬 |  | zh-38 |
| en-38 | You’re awake. Where shall we begin? | 灵感：Skyrim opening scene (setting only) | 致敬 | 早上 | zh-39 |
| en-39 | Sit by the fire. Tell me about today. | 灵感：Dark Souls bonfires | 致敬 | 晚上 | zh-40 |
| en-40 | One name, and it all comes back. |  | 直白 |  | zh-41 |
| en-41 | Memory paraphrases. Recordings quote. | 灵感：Ted Chiang, The Truth of Fact, the Truth of Feeling | 致敬 |  | zh-42 |

### 审校撤下的句子（2026-10-06，id 不再使用）

| id | 原句 | 为什么撤下 | 换成 |
|---|---|---|---|
| zh-12 | 博观而约取，厚积而薄发。 | 作文和励志里用得太多，和“千里之行”等已经排除的句子同类 | zh-43 |
| zh-15 | 其实地上本没有路；走的人多了，也便成了路。 | 鲁迅最常被引的一句，读者看到的是“开路、闯”，不是“用着用着就有条理”；分号位置各版本不同，读者会以为是错字 | zh-44 |
| zh-26 | 都还在你放下的地方。 | 实际是在安抚“东西没丢”，违反“不写安抚”的规则 | zh-45 |
| en-08 | Try to be one of the people on whom nothing is lost! | 祈使句加感叹号，在对用户提要求，有说教和压力感 | en-42 |
| en-25 | Right where you left it. | 同 zh-26，安抚 | en-43 |
