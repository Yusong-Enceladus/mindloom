import Foundation

// The patterns and word lists the outbound check refuses words by. None of
// these literals is shown to anyone (the copy guards skip this file); the
// fixed phrases that may be shown to the owner stay in OutboundCheck.swift.

extension OutboundCheck {
  static let months =
    "jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|june?|july?|aug(?:ust)?|sep(?:t(?:ember)?)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?"

  static let contactPattern = regex(
    #"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+|@|://|(?i:www\.)|(?<![0-9])1[3-9][0-9][ \-]?[0-9]{4}[ \-]?[0-9]{4}(?![0-9])|\+[0-9]{1,3}[ \-]?[0-9]{4,}"#
      // WeChat IDs, and handles written after a messenger's name (an ID has
      // a digit or an underscore, so 「Telegram specifications」 is not one).
      + #"|(?i:\bwxid_[a-z0-9_\-]+)|(?i:(?<![a-z])(?:微信|wechat|weixin|vx|qq|whatsapp|telegram)(?:\s*(?:号|id)\s*[:：]?\s*|\s*[:：]\s*|\s+)(?=[a-z0-9_\-]{5,})[a-z0-9\-]*[0-9_][a-z0-9_\-]*)"#
      // An address spelled out: 「alice at example dot com」, 「alice [at] example [dot] com」.
      + #"|(?i:\b[a-z0-9._%+\-]+(?:\s+|\s*[\(\[]\s*)(?:at|艾特)(?:\s+|\s*[\)\]]\s*)[a-z0-9\-]+(?:(?:\s+|\s*[\(\[]\s*)(?:dot|点)(?:\s+|\s*[\)\]]\s*)[a-z0-9\-]+)+)"#
  )
  static let secretPattern = regex(
    #"(?<![A-Za-z0-9])(?:sk|pk|rk|ghp|xox[abprs])[-_][A-Za-z0-9_\-]{6,}|(?=[A-Za-z0-9_\-]*[0-9])(?=[A-Za-z0-9_\-]*[A-Za-z])[A-Za-z0-9_\-]{16,}"#
  )
  static let moneyPattern = regex(
    #"[¥$€£￥]|[0-9零一二三四五六七八九十百千万两]\s*(?:元|块|万元|亿元|美元|美金|欧元|英镑)|(?i:\b(?:rmb|usd|cny|eur|gbp|dollars?)\b)"#
      // 「50k」, 「12万」, 「五万」, 「两千」 (a single digit before k is a
      // resolution or a generation: 「4K」, 「5G」).
      + #"|(?<![0-9.])[0-9]{2,}(?:\.[0-9]+)?\s*[kK](?![A-Za-z])|[0-9]+(?:\.[0-9]+)?\s*(?:万|千|亿)|[零一二三四五六七八九十两半几][零一二三四五六七八九十两百千]*\s*(?:万|千|亿)"#
  )
  static let datePattern = regex(
    #"[0-9]{1,2}\s*月\s*[0-9]{1,2}|[0-9]{4}\s*[-/.年]\s*[0-9]{1,2}|[0-9]{1,2}\s*[/.\-]\s*[0-9]{1,2}|[一二三四五六七八九十]{1,3}月[一二三四五六七八九十]{1,3}[日号]"#
      + #"|(?i:\b(?:"# + months + #")\.?\s+[0-9]{1,2}(?:st|nd|rd|th)?\b)"#
      + #"|(?i:\b[0-9]{1,2}(?:st|nd|rd|th)?\s+(?:of\s+)?(?:"# + months + #")\b)"#
  )
  static let spokenDigitsPattern = regex(#"[〇零一二三四五六七八九幺两]{4,}"#)
  /// House, room and floor numbers written the Chinese way: 「502室」,
  /// 「3号楼」, 「人民路100号」.
  static let houseNumberPattern = regex(
    #"[0-9]+\s*(?:号|弄|室|楼|栋|幢|单元|层|户)|(?:路|街|巷|弄|里|村|苑|小区|大厦)\s*[0-9]+"#
  )
  /// A mainland plate: a province's character, a letter, five or six
  /// letters and digits (at least three digits, so 「新iPhone」 is not one).
  static let platePattern = regex(
    #"[京津沪渝冀豫云辽黑湘皖鲁新苏浙赣鄂桂甘晋蒙陕吉闽贵粤青藏川宁琼][A-Za-z]\s?[·・]?\s?([A-Za-z0-9]{5,6})(?![A-Za-z0-9])"#
  )

  /// A DOI's suffix: contacts, token-shaped secrets and runs of eleven or
  /// more digits (phone, ID and card numbers). A general "long code" rule
  /// would refuse real DOIs ("s41586-020-2649-2", "3292500.3330701").
  static let identifierSecretPattern = regex(
    #"(?<![A-Za-z0-9])(?:sk|pk|rk|ghp|xox[abprs])[-_][A-Za-z0-9_\-]{6,}|eyJ[A-Za-z0-9_\-]{8,}|(?<![0-9])[0-9]{11,}(?![0-9])"#
  )

  static let addressIdentifierPattern = regex(
    #"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}|(?<![0-9])1[3-9][0-9]{9}(?![0-9])|(?<![A-Za-z0-9])(?:sk|ghp|xox[abprs])[-_][A-Za-z0-9_\-]{10,}|eyJ[A-Za-z0-9_\-]{8,}\.eyJ"#
  )
}

/// Words about health: a matter or a query with them never goes online
/// (MATTER-MINIMUM §5; ToolMinimize: a hospital's name alone can reveal a
/// diagnosis). A word list is a backstop only: the organizer marks a
/// health matter (`LookupRequest.healthRelated`) and then nothing is sent.
enum HealthWords {
  static let han = [
    "医院", "诊所", "门诊", "急诊", "住院", "病", "症", "癌", "瘤", "抑郁", "焦虑", "心理咨询", "精神科",
    "怀孕", "孕", "流产", "药", "处方", "手术", "体检", "化验", "诊断", "治疗", "康复", "艾滋", "牙科", "眼科",
    "妇科", "男科", "皮肤科", "医生", "医师", "疫苗", "胰岛素", "血压", "血糖", "血脂", "感冒", "发烧", "发热",
    "咳嗽", "核磁", "挂号", "复诊", "理疗", "针灸", "牙医", "体温", "过敏", "哮喘", "心脏", "中风", "骨折",
    "感染", "新冠", "核酸", "透析", "化疗", "放疗", "月经", "避孕", "产检", "生育", "失眠", "整形", "医美",
    "戒烟", "戒酒", "护理", "保健", "疗养", "疼痛", "头痛", "头疼", "残疾", "中医", "医疗", "医保",
  ]
  /// Latin stems matched anywhere inside a word ("chemotherapy").
  static let stems = [
    "hospital", "clinic", "diagnos", "cancer", "tumor", "tumour", "diabet", "depress", "anxiet", "therap",
    "psychiatr", "psycholog", "pregnan", "abortion", "prescription", "surger", "surgic", "symptom", "disease",
    "medication", "rehab", "oncolog", "dentist", "vaccin", "insulin", "influenza", "allerg", "asthma",
    "pharmac", "dermatolog", "gynec", "gynaec", "urolog", "cardiolog", "neurolog", "dialysis", "chemo",
    "fertility", "contracepti", "menstru", "obstetric", "pediatric", "paediatric", "covid", "coronavirus",
    "hypertension", "epilep", "alzheimer", "dementia", "autis", "hepatitis", "tubercul", "chlamydia",
    "syphilis", "herpes", "ultrasound", "mammogra", "biopsy", "orthodont", "ophthalm", "optometr", "addiction",
    "overdose", "suicid", "nursing",
  ]
  /// Words that contain a stem and are not about health.
  static let exceptions: Set<String> = ["hospitality", "hospitalities"]
  /// Short Latin words matched whole.
  static let words: Set<String> = [
    "hiv", "aids", "std", "stds", "sti", "ivf", "icu", "mri", "hpv", "flu", "pcr", "adhd", "ocd", "ptsd",
    "copd", "dental", "doctor", "doctors", "nurse", "nurses", "physician", "physicians",
  ]
  /// Two-word phrases ("blood pressure", "CT scan").
  static let phrases: [[String]] = [
    ["blood", "pressure"], ["blood", "test"], ["blood", "sugar"], ["mental", "health"], ["ct", "scan"],
    ["x", "ray"], ["sexual", "health"], ["self", "harm"],
  ]

  static func matches(_ text: OutboundCheck.Folded) -> Bool {
    if han.contains(where: { text.key.contains($0) }) { return true }
    for (index, token) in text.tokens.enumerated() {
      if words.contains(token) { return true }
      if !exceptions.contains(token), stems.contains(where: { token.contains($0) }) { return true }
      if index + 1 < text.tokens.count, phrases.contains([token, text.tokens[index + 1]]) { return true }
    }
    return false
  }
}
