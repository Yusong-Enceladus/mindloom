import Foundation

/// Answers the spoken questions that have exactly one right answer.
///
/// A 1.7B model answers "十七乘以二十三等于多少" with 455, and "一英里等于多少
/// 公里" with 0.62137 — the conversion inverted. A 4B would be wrong less
/// often rather than reliably right, because a language model does arithmetic
/// by resemblance to arithmetic it has seen. These questions are decidable,
/// and a decidable question should not be asked of a model at all.
///
/// This is the same rule the rest of the pipeline runs on: the freedom a job
/// gives a model must be no greater than the model can carry. Tidying is
/// clamped to deletion. Translating is handed to an engine built for it.
/// Arithmetic is computed.
///
/// Anything this does not recognise returns nil and goes to the model
/// unchanged, so the narrowness is a feature: it never guesses.
public enum SpokenCalculation {
  /// The answer to a spoken calculation, or nil when the question is not one.
  public static func answer(to question: String) -> String? {
    let normalized = normalize(question)
    if let conversion = unitConversion(in: normalized) { return conversion }
    if let arithmetic = arithmetic(in: normalized) { return arithmetic }
    return nil
  }

  // MARK: - Normalisation

  /// Full-width punctuation, spoken operators and Chinese numerals become the
  /// ASCII forms the rest of this file matches on.
  static func normalize(_ question: String) -> String {
    var text = question.lowercased()
    for (from, to) in [
      ("＋", "+"), ("－", "-"), ("×", "*"), ("÷", "/"), ("＝", "="), ("（", "("),
      ("）", ")"), ("．", "."), ("　", " "),
      ("乘以", "*"), ("乘上", "*"), ("乘", "*"),
      ("除以", "/"), ("除", "/"),
      ("加上", "+"), ("加", "+"),
      ("减去", "-"), ("减", "-"),
      (" times ", "*"), (" plus ", "+"), (" minus ", "-"), (" divided by ", "/"),
    ] {
      text = text.replacingOccurrences(of: from, with: to)
    }
    return chineseNumeralsReplaced(in: text)
  }

  /// Rewrites runs of Chinese numerals as digits, leaving everything else.
  static func chineseNumeralsReplaced(in text: String) -> String {
    let digits = Set("零〇一二两三四五六七八九十百千万亿")
    var output = ""
    var run = ""
    for character in text {
      if digits.contains(character) {
        run.append(character)
        continue
      }
      if !run.isEmpty {
        output += chineseNumber(run).map { formatted($0) } ?? run
        run = ""
      }
      output.append(character)
    }
    if !run.isEmpty {
      output += chineseNumber(run).map { formatted($0) } ?? run
    }
    return output
  }

  /// Chinese numerals up to 亿, including the bare "十五" form and the
  /// colloquial "三百五", where a digit left hanging after a unit means the
  /// next unit down — three hundred and fifty, not three hundred and five.
  static func chineseNumber(_ text: String) -> Double? {
    let units: [Character: Double] = ["十": 10, "百": 100, "千": 1_000]
    let sections: [Character: Double] = ["万": 10_000, "亿": 100_000_000]
    let ones: [Character: Double] = [
      "零": 0, "〇": 0, "一": 1, "二": 2, "两": 2, "三": 3, "四": 4, "五": 5,
      "六": 6, "七": 7, "八": 8, "九": 9,
    ]
    var total = 0.0
    var section = 0.0
    var current = 0.0
    var lastUnit = 0.0
    var sawZero = false
    var sawAnything = false
    for character in text {
      if character == "零" || character == "〇" {
        sawZero = true
        current = 0
        sawAnything = true
      } else if let digit = ones[character] {
        current = digit
        sawAnything = true
      } else if let unit = units[character] {
        // "十五" means fifteen: a bare 十 carries an implicit one.
        section += (current == 0 ? 1 : current) * unit
        current = 0
        lastUnit = unit
        sawZero = false
        sawAnything = true
      } else if let scale = sections[character] {
        total = (total + section + current) * scale
        section = 0
        current = 0
        lastUnit = 0
        sawZero = false
        sawAnything = true
      } else {
        return nil
      }
    }
    guard sawAnything else { return nil }
    // 三百五 → 350. An explicit 零 says the digit is the units place, so
    // 一千零八 stays 1008.
    if current > 0, lastUnit >= 10, !sawZero {
      current *= lastUnit / 10
    }
    return total + section + current
  }

  // MARK: - Arithmetic

  /// Evaluates a plain expression of numbers and the four operators.
  ///
  /// Written out rather than handed to `NSExpression`, which evaluates
  /// integer literals with integer semantics — seven divided by two would
  /// come back as three, and five divided by zero as zero. A tool whose only
  /// purpose is being reliably right cannot have either.
  static func arithmetic(in text: String) -> String? {
    let stripped = text.filter { !" 等于多少是结果答案吗？?=".contains($0) }
    guard !stripped.isEmpty,
      stripped.rangeOfCharacter(from: CharacterSet(charactersIn: "+-*/")) != nil,
      stripped.allSatisfy({ "0123456789.+-*/()".contains($0) }),
      stripped.rangeOfCharacter(from: CharacterSet.decimalDigits) != nil
    else { return nil }
    guard let value = evaluate(stripped), value.isFinite else { return nil }
    return formatted(value)
  }

  /// Shunting-yard, in doubles, refusing anything malformed.
  static func evaluate(_ expression: String) -> Double? {
    var numbers: [Double] = []
    var operators: [Character] = []
    let precedence: [Character: Int] = ["+": 1, "-": 1, "*": 2, "/": 2]

    func apply() -> Bool {
      guard let op = operators.popLast(), numbers.count >= 2 else { return false }
      let right = numbers.removeLast()
      let left = numbers.removeLast()
      switch op {
      case "+": numbers.append(left + right)
      case "-": numbers.append(left - right)
      case "*": numbers.append(left * right)
      case "/":
        guard right != 0 else { return false }
        numbers.append(left / right)
      default: return false
      }
      return true
    }

    var index = expression.startIndex
    var expectingValue = true
    while index < expression.endIndex {
      let character = expression[index]
      if character.isNumber || character == "." {
        var digits = ""
        while index < expression.endIndex,
          expression[index].isNumber || expression[index] == "."
        {
          digits.append(expression[index])
          index = expression.index(after: index)
        }
        guard let value = Double(digits) else { return nil }
        numbers.append(value)
        expectingValue = false
        continue
      }
      if character == "(" {
        operators.append(character)
        expectingValue = true
      } else if character == ")" {
        while operators.last != nil, operators.last != "(" {
          guard apply() else { return nil }
        }
        guard operators.popLast() == "(" else { return nil }
        expectingValue = false
      } else if let level = precedence[character] {
        // A leading minus is a sign, not a subtraction.
        if expectingValue, character == "-" {
          numbers.append(0)
        } else if expectingValue {
          return nil
        }
        while let top = operators.last, let topLevel = precedence[top], topLevel >= level {
          guard apply() else { return nil }
        }
        operators.append(character)
        expectingValue = true
      } else {
        return nil
      }
      index = expression.index(after: index)
    }
    guard !expectingValue else { return nil }
    while !operators.isEmpty {
      guard operators.last != "(" else { return nil }
      guard apply() else { return nil }
    }
    guard numbers.count == 1 else { return nil }
    return numbers[0]
  }

  // MARK: - Units

  /// One measured quantity converted into another unit.
  static func unitConversion(in text: String) -> String? {
    guard let target = unit(namedIn: text, excluding: nil) else { return nil }
    guard let (amount, source) = quantity(in: text, otherThan: target.name) else {
      return nil
    }
    guard source.family == target.family else { return nil }
    let converted = Measurement(value: amount, unit: source.dimension)
      .converted(to: target.dimension).value
    return "\(formatted(amount))\(source.name) = \(formatted(converted))\(target.name)"
  }

  /// Which quantity a unit measures. Stated rather than inferred from the
  /// class: `type(of:)` on Foundation's predefined units does not reliably
  /// identify the dimension, and a silently mismatched conversion is exactly
  /// the kind of confident wrong answer this file exists to prevent.
  enum Family: Equatable {
    case length
    case mass
    case temperature
    case volume
  }

  struct NamedUnit {
    let name: String
    let dimension: Dimension
    let family: Family
  }

  /// The units people actually dictate.
  static let units: [(String, Dimension, Family)] = [
    ("公里", UnitLength.kilometers, .length), ("千米", UnitLength.kilometers, .length),
    ("英里", UnitLength.miles, .length), ("海里", UnitLength.nauticalMiles, .length),
    ("厘米", UnitLength.centimeters, .length), ("毫米", UnitLength.millimeters, .length),
    ("英尺", UnitLength.feet, .length), ("英寸", UnitLength.inches, .length),
    ("米", UnitLength.meters, .length), ("码", UnitLength.yards, .length),
    ("公斤", UnitMass.kilograms, .mass), ("千克", UnitMass.kilograms, .mass),
    ("磅", UnitMass.pounds, .mass), ("盎司", UnitMass.ounces, .mass),
    ("克", UnitMass.grams, .mass), ("吨", UnitMass.metricTons, .mass),
    ("斤", jin, .mass),
    ("摄氏度", UnitTemperature.celsius, .temperature),
    ("华氏度", UnitTemperature.fahrenheit, .temperature),
    ("毫升", UnitVolume.milliliters, .volume), ("加仑", UnitVolume.gallons, .volume),
    ("升", UnitVolume.liters, .volume),
    ("kilometers", UnitLength.kilometers, .length),
    ("kilometres", UnitLength.kilometers, .length),
    ("miles", UnitLength.miles, .length), ("mile", UnitLength.miles, .length),
    ("km", UnitLength.kilometers, .length), ("meters", UnitLength.meters, .length),
    ("metres", UnitLength.meters, .length), ("feet", UnitLength.feet, .length),
    ("inches", UnitLength.inches, .length), ("pounds", UnitMass.pounds, .mass),
    ("kilograms", UnitMass.kilograms, .mass), ("kg", UnitMass.kilograms, .mass),
    ("lbs", UnitMass.pounds, .mass), ("liters", UnitVolume.liters, .volume),
    ("litres", UnitVolume.liters, .volume),
  ]

  /// The market catty, which macOS has no unit for and which is exactly half
  /// a kilogram by the modern Chinese definition.
  static let jin = UnitMass(
    symbol: "jin", converter: UnitConverterLinear(coefficient: 0.5))

  /// The unit the question converts *into* — the one furthest along the
  /// sentence. Longest name wins at the same place, because 公斤 contains 斤
  /// and 厘米 contains 米, and matching the short one turned "六英尺是多少
  /// 厘米" into an answer in metres.
  static func unit(namedIn text: String, excluding excluded: String?) -> NamedUnit? {
    var best: (end: String.Index, length: Int, unit: NamedUnit)?
    for (name, dimension, family) in units where name != excluded {
      guard let range = text.range(of: name, options: .backwards) else { continue }
      if let current = best {
        if range.upperBound < current.end { continue }
        if range.upperBound == current.end, name.count < current.length { continue }
      }
      best = (
        range.upperBound, name.count,
        NamedUnit(name: name, dimension: dimension, family: family)
      )
    }
    return best?.unit
  }

  /// The amount and the unit it was given in, taken from the front of the
  /// question so that "一英里等于多少公里" reads one mile, not one kilometre.
  static func quantity(in text: String, otherThan excluded: String) -> (Double, NamedUnit)? {
    var best: (start: String.Index, length: Int, amount: Double, unit: NamedUnit)?
    for (name, dimension, family) in units where name != excluded {
      guard let range = text.range(of: name) else { continue }
      let prefix = text[text.startIndex..<range.lowerBound]
      guard let amount = trailingNumber(in: String(prefix)) else { continue }
      // Earliest quantity in the sentence; at the same place the longer name
      // wins, so "100 miles" is miles rather than the "mile" inside it.
      if let current = best {
        if range.lowerBound > current.start { continue }
        if range.lowerBound == current.start, name.count < current.length { continue }
      }
      best = (
        range.lowerBound, name.count, amount,
        NamedUnit(name: name, dimension: dimension, family: family)
      )
    }
    guard let best else { return nil }
    return (best.amount, best.unit)
  }

  static func trailingNumber(in text: String) -> Double? {
    var digits = ""
    for character in text.reversed() {
      if character.isNumber || character == "." {
        digits.insert(character, at: digits.startIndex)
      } else if digits.isEmpty {
        continue
      } else {
        break
      }
    }
    return Double(digits)
  }

  // MARK: - Formatting

  /// Enough digits to be useful, none of the noise a raw double carries.
  /// `%g` was not enough: it keeps six significant figures, which turned
  /// 160.9344 km into 160.934.
  static func formatted(_ value: Double) -> String {
    if value == value.rounded(), abs(value) < 1e15 {
      return String(Int64(value))
    }
    var text = String(format: "%.4f", value)
    while text.hasSuffix("0") { text.removeLast() }
    if text.hasSuffix(".") { text.removeLast() }
    return text
  }
}
