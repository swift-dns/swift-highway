// Generates the C header of the ops, the Swift layer over it, the C++ header of the Highway ops
// they are tested against, the tests that compare the two, and the functions that put both of
// them into machine code to be compared, from the op list below.
//
// Run from the repository root:
//
//     swift utils/GenerateHighwayOps.swift

import Foundation

enum Category: Hashable {
    case unsignedInteger
    case signedInteger
    case float
}

struct Element {
    let suffix: String
    let cType: String
    let swiftType: String
    let category: Category
    let bits: Int

    var tag: String { "Tag\(suffix)" }
    var vector: String { "Vector\(suffix)" }
    var mask: String { "Mask\(suffix)" }
    var namespace: String { "Highway\(swiftType)" }
    var laneCount: Int { 128 / bits }
    var cSuffix: String { suffix.lowercased() }
    var cVector: String { "chighway_ops_vector_\(cSuffix)" }
    var cMask: String { "chighway_ops_mask_\(cSuffix)" }
    var cUnsignedLane: String { "uint\(bits)_t" }
    var cUnsignedVector: String { "chighway_ops_vector_u\(bits)" }
    var cMaskLane: String { "int\(bits)_t" }
    var swiftMaskLane: String { "Int\(bits)" }
    var swiftVector: String { "SIMD\(laneCount)<\(swiftType)>" }
    var swiftMask: String { "SIMDMask<SIMD\(laneCount)<\(swiftMaskLane)>>" }
}

let elements: [Element] = [
    Element(
        suffix: "U8",
        cType: "uint8_t",
        swiftType: "UInt8",
        category: .unsignedInteger,
        bits: 8
    ),
    Element(
        suffix: "U16",
        cType: "uint16_t",
        swiftType: "UInt16",
        category: .unsignedInteger,
        bits: 16
    ),
    Element(
        suffix: "U32",
        cType: "uint32_t",
        swiftType: "UInt32",
        category: .unsignedInteger,
        bits: 32
    ),
    Element(
        suffix: "U64",
        cType: "uint64_t",
        swiftType: "UInt64",
        category: .unsignedInteger,
        bits: 64
    ),
    Element(suffix: "I8", cType: "int8_t", swiftType: "Int8", category: .signedInteger, bits: 8),
    Element(
        suffix: "I16",
        cType: "int16_t",
        swiftType: "Int16",
        category: .signedInteger,
        bits: 16
    ),
    Element(
        suffix: "I32",
        cType: "int32_t",
        swiftType: "Int32",
        category: .signedInteger,
        bits: 32
    ),
    Element(
        suffix: "I64",
        cType: "int64_t",
        swiftType: "Int64",
        category: .signedInteger,
        bits: 64
    ),
    Element(suffix: "F32", cType: "float", swiftType: "Float", category: .float, bits: 32),
    Element(suffix: "F64", cType: "double", swiftType: "Double", category: .float, bits: 64),
]

struct Applies {
    var categories: Set<Category>
    var bits: Set<Int>?

    func matches(_ element: Element) -> Bool {
        guard categories.contains(element.category) else { return false }
        guard let bits else { return true }
        return bits.contains(element.bits)
    }

    static let all = Applies(categories: [.unsignedInteger, .signedInteger, .float], bits: nil)
    static let integer = Applies(categories: [.unsignedInteger, .signedInteger], bits: nil)
    static let unsigned = Applies(categories: [.unsignedInteger], bits: nil)
    static let float = Applies(categories: [.float], bits: nil)
    static let signedOrFloat = Applies(categories: [.signedInteger, .float], bits: nil)

    static func integer(bits: Set<Int>) -> Applies {
        Applies(categories: [.unsignedInteger, .signedInteger], bits: bits)
    }
    static func unsigned(bits: Set<Int>) -> Applies {
        Applies(categories: [.unsignedInteger], bits: bits)
    }
    static func all(bits: Set<Int>) -> Applies {
        Applies(categories: [.unsignedInteger, .signedInteger, .float], bits: bits)
    }
}

// A `tag` is not a parameter of the generated functions; it marks where Highway wants the tag
// in its own argument list.
enum Parameter {
    case tag
    case vector
    case indices
    case mask
    case lane
    case constLanePointer
    case lanePointer
    case count
    case shiftAmount
    case laneAmount
    case outVector
}

enum ReturnType {
    case vector
    case mask
    case lane
    case count
    case index
    case boolean
    case void
}

// How much of a span the span form of a pointer op reads or writes, from the span's start.
// `first` is as many lanes as the span has, up to a vector, which a pointer op takes as `count`.
// An `aligned` op also needs the span to start at an address aligned to the vector size.
enum SpanExtent {
    case vectors(Int, aligned: Bool = false)
    case first
}

struct TargetBodies<Input> {
    var neon: ((Input) -> String?)?
    var sse4: ((Input) -> String?)?
    var ssse3: ((Input) -> String?)?
    var sse2: ((Input) -> String?)?
}

struct Op {
    let swiftName: String
    let highwayName: String
    let parameters: [Parameter]
    let returns: ReturnType
    let applies: Applies
    var documentation: String = ""
    let span: SpanExtent?
    let targets: TargetBodies<Element>
    let portable: (Element) -> String

    init(
        _ swiftName: String,
        _ highwayName: String,
        _ parameters: [Parameter],
        _ returns: ReturnType,
        _ applies: Applies,
        _ documentation: String = "",
        span: SpanExtent? = nil,
        targets: TargetBodies<Element> = TargetBodies(),
        portable: @escaping (Element) -> String
    ) {
        self.swiftName = swiftName
        self.highwayName = highwayName
        self.parameters = parameters
        self.returns = returns
        self.applies = applies
        self.documentation = documentation
        self.span = span
        self.targets = targets
        self.portable = portable
    }
}

func compoundLiteral(_ type: String, _ values: [String]) -> String {
    "(\(type)){\(values.joined(separator: ", "))}"
}

func splat(_ value: String, as type: String, lanes: Int) -> String {
    compoundLiteral(type, Array(repeating: value, count: lanes))
}

func iota(as type: String, lanes: Int) -> String {
    compoundLiteral(type, (0..<lanes).map(String.init))
}

func clampedCount(to lanes: Int) -> String {
    "(count < \(lanes) ? count : \(lanes))"
}

func unsignedBits(_ operand: String, of element: Element) -> String {
    element.category == .unsignedInteger ? operand : "(\(element.cUnsignedVector))\(operand)"
}

func fromUnsignedBits(_ expression: String, of element: Element) -> String {
    element.category == .unsignedInteger ? expression : "(\(element.cVector))(\(expression))"
}

func binaryArithmetic(_ symbol: String, for element: Element) -> String {
    guard element.category == .signedInteger else { return "return a \(symbol) b;" }
    let unsigned = element.cUnsignedVector
    return "return (\(element.cVector))((\(unsigned))a \(symbol) (\(unsigned))b);"
}

func vectorComparison(_ symbol: String, for element: Element) -> String {
    "return (\(element.cMask))(a \(symbol) b);"
}

func bitSelect(_ mask: String, _ a: String, _ b: String, of element: Element) -> String {
    let unsignedMask = "(\(element.cUnsignedVector))\(mask)"
    let chosen = "(\(unsignedMask) & \(unsignedBits(a, of: element)))"
    let rest = "(~\(unsignedMask) & \(unsignedBits(b, of: element)))"
    return fromUnsignedBits("\(chosen) | \(rest)", of: element)
}

func infinity(of element: Element) -> String {
    element.bits == 32 ? "__builtin_inff()" : "__builtin_inf()"
}

func elementwiseExtremum(_ name: String, comparing symbol: String, for element: Element) -> String {
    guard element.category == .float else { return "return __builtin_elementwise_\(name)(a, b);" }
    let mask = element.cMask
    return """
        \(mask) take = (\(mask))(a \(symbol) b) | ((\(mask))(b != b) & (\(mask))(a == a));
        return \(bitSelect("take", "a", "b", of: element));
        """
}

func reducedExtremum(
    _ name: String,
    comparing symbol: String,
    from start: String,
    for element: Element
) -> String {
    guard element.category == .float else { return "return __builtin_reduce_\(name)(a);" }
    return """
        \(element.cType) result = \(start);
        for (size_t i = 0; i < \(element.laneCount); ++i) {
          result = result \(symbol) a[i] ? result : a[i];
        }
        return result;
        """
}

func interleavedIndex(_ channel: Int, of channels: Int) -> String {
    channel == 0 ? "\(channels) * i" : "\(channels) * i + \(channel)"
}

func loadInterleaved(channels: Int, for element: Element) -> String {
    let names = (0..<channels).map { "r\($0)" }
    let loads = names.enumerated().map { channel, name in
        "  \(name)[i] = from[\(interleavedIndex(channel, of: channels))];"
    }
    let stores = names.indices.map { "*v\($0) = r\($0);" }
    return """
        \(element.cVector) \(names.joined(separator: ", "));
        for (size_t i = 0; i < \(element.laneCount); ++i) {
        \(loads.joined(separator: "\n"))
        }
        \(stores.joined(separator: "\n"))
        """
}

func storeInterleaved(channels: Int, for element: Element) -> String {
    let stores = ["a", "b", "c", "d"].prefix(channels).enumerated().map { channel, name in
        "  to[\(interleavedIndex(channel, of: channels))] = \(name)[i];"
    }
    return """
        for (size_t i = 0; i < \(element.laneCount); ++i) {
        \(stores.joined(separator: "\n"))
        }
        """
}

struct RawVector {
    let name: String
    let lane: String
    let attribute: String
}

func neonVector(_ suffix: String) -> String {
    "chighway_ops_neon_\(suffix)"
}

func x86Vector(_ suffix: String) -> String {
    "chighway_ops_x86_\(suffix)"
}

let neonVectors: [RawVector] = [
    RawVector(name: neonVector("i8"), lane: "int8_t", attribute: "neon_vector_type(16)"),
    RawVector(name: neonVector("f32"), lane: "float", attribute: "neon_vector_type(4)"),
    RawVector(name: neonVector("f64"), lane: "double", attribute: "neon_vector_type(2)"),
]

let x86Vectors: [RawVector] = [
    RawVector(name: x86Vector("i8"), lane: "char", attribute: "vector_size(16)"),
    RawVector(name: x86Vector("i16"), lane: "short", attribute: "vector_size(16)"),
    RawVector(name: x86Vector("i32"), lane: "int", attribute: "vector_size(16)"),
    RawVector(name: x86Vector("i64"), lane: "long long", attribute: "vector_size(16)"),
    RawVector(name: x86Vector("f32"), lane: "float", attribute: "vector_size(16)"),
    RawVector(name: x86Vector("f64"), lane: "double", attribute: "vector_size(16)"),
]

func neonTypeCode(of element: Element) -> Int {
    let quad = 32
    switch element.category {
    case .unsignedInteger: return quad + 16 + (element.bits / 8).trailingZeroBitCount
    case .signedInteger: return quad + (element.bits / 8).trailingZeroBitCount
    case .float: return quad + (element.bits == 32 ? 9 : 10)
    }
}

func neonBuiltin(
    _ name: String,
    _ arguments: [String],
    code: Int,
    for element: Element
) -> String {
    let operands = arguments.map { "(\(neonVector("i8")))\($0)" } + [String(code)]
    return "(\(element.cVector))__builtin_neon_\(name)(\(operands.joined(separator: ", ")))"
}

func neonShift(negated: Bool, for element: Element) -> String {
    let lanes = element.laneCount
    let count = splat("(\(element.cUnsignedLane))bits", as: element.cUnsignedVector, lanes: lanes)
    let amounts = ["a", negated ? "(-count)" : "count"]
    let shifted = neonBuiltin("vshlq_v", amounts, code: neonTypeCode(of: element), for: element)
    return """
        const \(element.cUnsignedVector) count = \(count);
        return \(shifted);
        """
}

func neonReduction(_ name: String, for element: Element) -> String? {
    guard element.category == .float else { return nil }
    return "return __builtin_neon_\(name)_\(element.cSuffix)((\(neonVector(element.cSuffix)))a);"
}

func neonTableLookup(_ bytes: String, _ indices: String, for element: Element) -> String {
    neonBuiltin("vqtbl1q_v", [bytes, indices], code: 48, for: element)
}

let neonNibbles = """
    typedef uint16_t wide_vector __attribute__((vector_size(16)));
    typedef uint8_t narrow_vector __attribute__((vector_size(8)));
    const narrow_vector narrowed = __builtin_convertvector((wide_vector)mask >> 4, narrow_vector);
    const uint64_t nibbles = __builtin_bit_cast(uint64_t, narrowed);
    """

func neonFirstTrueIndex(for element: Element) -> String {
    """
    \(neonNibbles)
    return nibbles == 0 ? -1 : (intptr_t)(__builtin_ctzll(nibbles) / \(element.bits / 2));
    """
}

func neonSlide1Up(for element: Element) -> String {
    let lanes = element.laneCount
    let zero = compoundLiteral(element.cVector, ["0"])
    let indices = laneIndices(lanes - 1..<2 * lanes - 1)
    return "return __builtin_shufflevector(\(zero), a, \(indices));"
}

func x86Builtin(
    _ name: String,
    _ arguments: [String],
    as suffix: String,
    returning type: String
) -> String {
    let operands = arguments.map { "(\(x86Vector(suffix)))\($0)" }
    return "(\(type))__builtin_ia32_\(name)(\(operands.joined(separator: ", ")))"
}

func x86ShiftCount(_ amount: String) -> String {
    compoundLiteral(x86Vector("i32"), [amount, "0", "0", "0"])
}

func x86Shift(_ instruction: String, laneBits: Int, returning type: String) -> String {
    guard let suffix = [16: "w", 32: "d", 64: "q"][laneBits] else {
        fatalError("There is no x86 shift of \(laneBits)-bit lanes")
    }
    let name = "\(instruction)\(suffix)128"
    return x86Builtin(name, ["a", x86ShiftCount("bits")], as: "i\(laneBits)", returning: type)
}

func x86ShiftedLeft(for element: Element) -> String {
    guard element.bits == 8 else {
        return "return \(x86Shift("psll", laneBits: element.bits, returning: element.cVector));"
    }
    let unsigned = element.cUnsignedVector
    let shifted = x86Shift("psll", laneBits: 16, returning: unsigned)
    let mask = splat("mask", as: unsigned, lanes: element.laneCount)
    return """
        const uint8_t mask = (uint8_t)(0xFFu << (bits & 31));
        return \(fromUnsignedBits("\(shifted) & \(mask)", of: element));
        """
}

func x86ShiftedRight(for element: Element) -> String {
    let unsigned = element.cUnsignedVector
    switch (element.category, element.bits) {
    case (.unsignedInteger, 8):
        let shifted = x86Shift("psrl", laneBits: 16, returning: unsigned)
        let mask = splat("mask", as: unsigned, lanes: element.laneCount)
        return """
            const uint8_t mask = (uint8_t)(0xFF >> (bits & 31));
            return \(shifted) & \(mask);
            """
    case (.signedInteger, 8):
        let shifted = x86Shift("psrl", laneBits: 16, returning: unsigned)
        let mask = splat("mask", as: unsigned, lanes: element.laneCount)
        let signs = splat("sign", as: unsigned, lanes: element.laneCount)
        return """
            const uint8_t mask = (uint8_t)(0xFF >> (bits & 31));
            const uint8_t sign = (uint8_t)(0x80 >> (bits & 31));
            const \(unsigned) shifted = \(shifted) & \(mask);
            const \(unsigned) signs = \(signs);
            return (\(element.cVector))((shifted ^ signs) - signs);
            """
    case (.signedInteger, 64):
        let right = x86Shift("psrl", laneBits: 64, returning: element.cVector)
        let count = x86ShiftCount("(int)(64u - (unsigned)bits)")
        let sign = x86Builtin(
            "psllq128",
            ["(a < 0)", count],
            as: "i64",
            returning: element.cVector
        )
        return """
            const \(element.cVector) right = \(right);
            const \(element.cVector) sign = \(sign);
            return right | sign;
            """
    default:
        let instruction = element.category == .unsignedInteger ? "psrl" : "psra"
        let shifted = x86Shift(instruction, laneBits: element.bits, returning: element.cVector)
        return "return \(shifted);"
    }
}

func x86Extremum(
    _ name: String,
    _ first: String,
    _ second: String,
    for element: Element
) -> String {
    "__builtin_ia32_\(name)\(element.bits == 32 ? "ps" : "pd")(\(first), \(second))"
}

func x86Reduction(
    for element: Element,
    combining combine: (_ first: String, _ second: String) -> String
) -> String? {
    guard element.category == .float else { return nil }
    let lanes = element.laneCount
    let reverse = (0..<lanes).reversed().map(String.init).joined(separator: ", ")
    let reversed = "const \(element.cVector) reversed = __builtin_shufflevector(a, a, \(reverse));"
    guard lanes == 4 else {
        return """
            \(reversed)
            const \(element.cVector) combined = \(combine("a", "reversed"));
            return combined[0];
            """
    }
    return """
        \(reversed)
        const \(element.cVector) pairs = \(combine("a", "reversed"));
        const \(element.cVector) swapped = __builtin_shufflevector(pairs, pairs, 1, 0, 3, 2);
        const \(element.cVector) combined = \(combine("pairs", "swapped"));
        return combined[0];
        """
}

func x86TableLookup(_ bytes: String, _ indices: String, for element: Element) -> String {
    x86Builtin("pshufb128", [bytes, indices], as: "i8", returning: element.cVector)
}

func slideUpConstants(for element: Element) -> String {
    let lanes = element.laneCount
    let zero = compoundLiteral(element.cVector, ["0"])
    let cases = (1..<lanes).map { amount in
        let indices = laneIndices(lanes - amount..<2 * lanes - amount)
        return "case \(amount): return __builtin_shufflevector(\(zero), a, \(indices));"
    }
    return """
        if (__builtin_constant_p(lanes)) {
          switch (lanes) {
        \(indented(indented((["case 0: return a;"] + cases).joined(separator: "\n"))))
          }
        }
        """
}

func slideUpIndices(for element: Element) -> String {
    let bytes = "chighway_ops_vector_u8"
    let first = splat("first", as: bytes, lanes: 16)
    return """
        const uint8_t first = (uint8_t)(0 - lanes * sizeof(\(element.cType)));
        const \(bytes) indices = \(first) + \(iota(as: bytes, lanes: 16));
        """
}

func x86SlideUp(for element: Element) -> String {
    let vector = x86Vector("i64")
    let left = x86Builtin(
        "psllq128",
        ["high", x86ShiftCount("shift")],
        as: "i64",
        returning: vector
    )
    let right = x86Builtin(
        "psrlq128",
        ["low", x86ShiftCount("64 - shift")],
        as: "i64",
        returning: vector
    )
    return """
        const \(vector) zero = {0, 0};
        const \(vector) whole = (\(vector))a;
        const \(vector) moved = __builtin_shufflevector(zero, whole, 0, 2);
        const long long selected = -(long long)(lanes >= \(element.laneCount / 2));
        const \(vector) mask = {selected, selected};
        const \(vector) high = (moved & mask) | (whole & ~mask);
        const \(vector) low = __builtin_shufflevector(zero, high, 0, 2);
        const int shift = (int)((lanes * \(element.bits)) & 63);
        return (\(element.cVector))(\(left) | \(right));
        """
}

func isInteger32(_ element: Element) -> Bool {
    element.bits == 32 && element.category != .float
}

func isFloat32(_ element: Element) -> Bool {
    element.bits == 32 && element.category == .float
}

func isSignedInteger64(_ element: Element) -> Bool {
    element.bits == 64 && element.category == .signedInteger
}

func x86Multiplying32(for element: Element) -> String {
    let i32 = x86Vector("i32")
    let i64 = x86Vector("i64")
    let evens = x86Builtin("pmuludq128", ["a", "b"], as: "i32", returning: i64)
    let odds = x86Builtin("pmuludq128", ["a_x3x1", "b_x3x1"], as: "i32", returning: i64)
    return """
        const \(i32) a_x3x1 = __builtin_shufflevector((\(i32))a, (\(i32))a, 1, 1, 3, 3);
        const \(i64) mullo_x2x0 = \(evens);
        const \(i32) b_x3x1 = __builtin_shufflevector((\(i32))b, (\(i32))b, 1, 1, 3, 3);
        const \(i64) mullo_x3x1 = \(odds);
        const \(i32) mul_20 = __builtin_shufflevector(
          (\(i32))mullo_x2x0, (\(i32))mullo_x2x0, 0, 2, 0, 2);
        const \(i32) mul_31 = __builtin_shufflevector(
          (\(i32))mullo_x3x1, (\(i32))mullo_x3x1, 0, 2, 0, 2);
        return (\(element.cVector))__builtin_shufflevector(mul_20, mul_31, 0, 4, 1, 5);
        """
}

func x86Int64Greater(
    _ first: String,
    _ second: String,
    native: Bool = false,
    for element: Element
) -> String {
    let mask = element.cMask
    guard !native else { return "const \(mask) mask = (\(mask))(\(first) > \(second));" }
    let i32 = x86Vector("i32")
    let i64 = x86Vector("i64")
    return """
        const \(i32) equal = (\(i32))\(first) == (\(i32))\(second);
        const \(i32) greater = (\(i32))\(first) > (\(i32))\(second);
        const \(i64) difference = (\(i64))\(second) - (\(i64))\(first);
        const \(i64) upper = (\(i64))greater | ((\(i64))equal & difference);
        const \(mask) mask = (\(mask))__builtin_shufflevector(
          (\(i32))upper, (\(i32))upper, 1, 1, 3, 3);
        """
}

func x86Int64Extremum(
    _ chosen: (first: String, second: String),
    native: Bool = false,
    for element: Element
) -> String {
    """
    \(x86Int64Greater("b", "a", native: native, for: element))
    return \(bitSelect("mask", chosen.first, chosen.second, of: element));
    """
}

func x86Int64Reduction(
    _ chosen: (first: String, second: String),
    native: Bool = false,
    for element: Element
) -> String {
    let selected = bitSelect("mask", chosen.first, chosen.second, of: element)
    return """
        const \(element.cVector) reversed = __builtin_shufflevector(a, a, 1, 0);
        \(x86Int64Greater("reversed", "a", native: native, for: element))
        const \(element.cVector) combined = \(selected);
        return combined[0];
        """
}

func x86Selecting(for element: Element) -> String {
    let (name, suffix) =
        element.category == .float
        ? ("blendv\(element.bits == 32 ? "ps" : "pd")", element.cSuffix)
        : ("pblendvb128", "i8")
    return x86Builtin(name, ["b", "a", "mask"], as: suffix, returning: element.cVector)
}

func x86Slide1UpFloat(for element: Element) -> String {
    let lanes = element.laneCount
    let zero = compoundLiteral(element.cVector, ["0"])
    let cleared = laneIndices(0..<lanes - 1) + ", \(2 * lanes - 1)"
    let rotated = laneIndices([lanes - 1] + Array(0..<lanes - 1))
    return """
        const \(element.cVector) cleared = __builtin_shufflevector(a, \(zero), \(cleared));
        return __builtin_shufflevector(cleared, cleared, \(rotated));
        """
}

func x86MaskBits(for element: Element) -> String {
    switch element.bits {
    case 8:
        return x86Builtin("pmovmskb128", ["mask"], as: "i8", returning: "int")
    case 16:
        let zero = compoundLiteral(x86Vector("i16"), ["0"])
        let packed = x86Builtin(
            "packsswb128",
            ["mask", zero],
            as: "i16",
            returning: x86Vector("i8")
        )
        return x86Builtin("pmovmskb128", [packed], as: "i8", returning: "int")
    case 32:
        return x86Builtin("movmskps", ["mask"], as: "f32", returning: "int")
    default:
        return x86Builtin("movmskpd", ["mask"], as: "f64", returning: "int")
    }
}

func x86AllTrue(for element: Element) -> String {
    let allBits = "0x\(String((1 << element.laneCount) - 1, radix: 16))"
    return "return \(x86MaskBits(for: element)) == \(allBits);"
}

func x86FirstTrueIndex(for element: Element) -> String {
    """
    const unsigned bits = (unsigned)\(x86MaskBits(for: element));
    return bits ? (intptr_t)__builtin_ctz(bits) : -1;
    """
}

func isInt64Widening(from narrow: Element, to wide: Element) -> Bool {
    isSignedInteger64(wide) && narrow.bits < 32
}

func x86Int64Promotion(of register: String, from narrow: Element, to wide: Element) -> String {
    let i8 = x86Vector("i8")
    let i16 = x86Vector("i16")
    let i32 = x86Vector("i32")
    let widened: String
    if narrow.bits == 8 {
        let pairs = laneIndices(unpackIndices(lanes: 16, upper: false))
        let quads = laneIndices(unpackIndices(lanes: 8, upper: false))
        widened = """
            const \(i8) pairs = __builtin_shufflevector(
              (\(i8))\(register), (\(i8))\(register), \(pairs));
            const \(i16) quads = __builtin_shufflevector((\(i16))pairs, (\(i16))pairs, \(quads));
            const \(i32) lanes = (\(i32))quads >> 24;
            """
    } else {
        let pairs = laneIndices(unpackIndices(lanes: 8, upper: false))
        widened = """
            const \(i16) pairs = __builtin_shufflevector(
              (\(i16))\(register), (\(i16))\(register), \(pairs));
            const \(i32) lanes = (\(i32))pairs >> 16;
            """
    }
    return """
        \(widened)
        const \(i16) signs = __builtin_shufflevector(
          (\(i16))lanes, (\(i16))lanes, \(laneIndices(1..<2, 1..<2, 3..<4, 3..<4, 4..<8)));
        return (\(wide.cVector))__builtin_shufflevector(lanes, (\(i32))signs, 0, 4, 1, 5);
        """
}

func x86Int64Widening(from narrow: Element, to wide: Element) -> String {
    """
    \(narrow.cVector) loaded;
    __builtin_memcpy(&loaded, from, \(wide.laneCount * narrow.bits / 8));
    \(x86Int64Promotion(of: "loaded", from: narrow, to: wide))
    """
}

func x86Int64LoadFirstWidening(from narrow: Element, to wide: Element) -> String {
    loadFirstTree(lanes: wide.laneCount, of: narrow, in: narrow, inserting: .unpack) {
        x86Int64Promotion(of: $0, from: narrow, to: wide)
    }
}

struct ShuffleStep {
    let name: String
    let first: String
    let second: String
    let laneBits: Int
    let indices: [Int]
    var isFloating = false

    static func lower(_ name: String, _ first: String, _ second: String, laneBits: Int) -> Self {
        let indices = unpackIndices(lanes: 128 / laneBits, upper: false)
        return Self(name: name, first: first, second: second, laneBits: laneBits, indices: indices)
    }

    static func upper(_ name: String, _ first: String, _ second: String, laneBits: Int) -> Self {
        let indices = unpackIndices(lanes: 128 / laneBits, upper: true)
        return Self(name: name, first: first, second: second, laneBits: laneBits, indices: indices)
    }

    static func oddEven(_ name: String, odd: String, even: String, laneBits: Int) -> Self {
        let lanes = 128 / laneBits
        let indices = (0..<lanes).map { $0 % 2 == 0 ? $0 : lanes + $0 }
        return Self(name: name, first: even, second: odd, laneBits: laneBits, indices: indices)
    }

    static func shiftedRight(
        _ name: String,
        _ source: String,
        lanes shift: Int,
        laneBits: Int
    ) -> Self {
        let zero = compoundLiteral(x86Vector("i\(laneBits)"), ["0"])
        let indices = (0..<128 / laneBits).map { $0 + shift }
        return Self(name: name, first: source, second: zero, laneBits: laneBits, indices: indices)
    }

    static func floating(
        _ name: String,
        _ first: String,
        _ second: String,
        indices: [Int],
        laneBits: Int
    ) -> Self {
        Self(
            name: name,
            first: first,
            second: second,
            laneBits: laneBits,
            indices: indices,
            isFloating: true
        )
    }
}

func x86Shuffles(_ steps: [ShuffleStep], for element: Element) -> [String] {
    steps.map { step in
        let isNative = element.category == .float && step.laneBits == element.bits
        let type = x86Vector("\(step.isFloating || isNative ? "f" : "i")\(step.laneBits)")
        let operands = "(\(type))\(step.first), (\(type))\(step.second)"
        let indices = laneIndices(step.indices)
        return "const \(type) \(step.name) = __builtin_shufflevector(\(operands), \(indices));"
    }
}

func x86LoadInterleaved4Steps(for element: Element) -> [ShuffleStep] {
    switch element.bits {
    case 8:
        return [
            .lower("v5140", "vA", "vB", laneBits: 8),
            .lower("vd9c8", "vC", "vD", laneBits: 8),
            .upper("v7362", "vA", "vB", laneBits: 8),
            .upper("vfbea", "vC", "vD", laneBits: 8),
            .lower("v6420", "v5140", "v7362", laneBits: 8),
            .lower("veca8", "vd9c8", "vfbea", laneBits: 8),
            .upper("v7531", "v5140", "v7362", laneBits: 8),
            .upper("vfdb9", "vd9c8", "vfbea", laneBits: 8),
            .lower("v10L", "v6420", "v7531", laneBits: 8),
            .lower("v10U", "veca8", "vfdb9", laneBits: 8),
            .upper("v32L", "v6420", "v7531", laneBits: 8),
            .upper("v32U", "veca8", "vfdb9", laneBits: 8),
            .lower("r0", "v10L", "v10U", laneBits: 64),
            .upper("r1", "v10L", "v10U", laneBits: 64),
            .lower("r2", "v32L", "v32U", laneBits: 64),
            .upper("r3", "v32L", "v32U", laneBits: 64),
        ]
    case 16:
        return [
            .lower("va820", "vA", "vB", laneBits: 16),
            .lower("vec64", "vC", "vD", laneBits: 16),
            .upper("vb931", "vA", "vB", laneBits: 16),
            .upper("vfd75", "vC", "vD", laneBits: 16),
            .lower("v10b830", "va820", "vb931", laneBits: 16),
            .lower("v10fc74", "vec64", "vfd75", laneBits: 16),
            .upper("v32b830", "va820", "vb931", laneBits: 16),
            .upper("v32fc74", "vec64", "vfd75", laneBits: 16),
            .lower("r0", "v10b830", "v10fc74", laneBits: 64),
            .upper("r1", "v10b830", "v10fc74", laneBits: 64),
            .lower("r2", "v32b830", "v32fc74", laneBits: 64),
            .upper("r3", "v32b830", "v32fc74", laneBits: 64),
        ]
    case 32:
        return [
            .lower("v10e", "vA", "vC", laneBits: 32),
            .lower("v10o", "vB", "vD", laneBits: 32),
            .upper("v32e", "vA", "vC", laneBits: 32),
            .upper("v32o", "vB", "vD", laneBits: 32),
            .lower("r0", "v10e", "v10o", laneBits: 32),
            .upper("r1", "v10e", "v10o", laneBits: 32),
            .lower("r2", "v32e", "v32o", laneBits: 32),
            .upper("r3", "v32e", "v32o", laneBits: 32),
        ]
    default:
        return [
            .lower("r0", "vA", "vC", laneBits: 64),
            .upper("r1", "vA", "vC", laneBits: 64),
            .lower("r2", "vB", "vD", laneBits: 64),
            .upper("r3", "vB", "vD", laneBits: 64),
        ]
    }
}

func x86StoreInterleaved4Steps(for element: Element) -> [ShuffleStep] {
    let bits = element.bits
    guard bits < 64 else {
        return [
            .lower("vA", "a", "b", laneBits: 64),
            .lower("vB", "c", "d", laneBits: 64),
            .upper("vC", "a", "b", laneBits: 64),
            .upper("vD", "c", "d", laneBits: 64),
        ]
    }
    return [
        .lower("v10L", "a", "b", laneBits: bits),
        .lower("v32L", "c", "d", laneBits: bits),
        .upper("v10U", "a", "b", laneBits: bits),
        .upper("v32U", "c", "d", laneBits: bits),
        .lower("vA", "v10L", "v32L", laneBits: 2 * bits),
        .upper("vB", "v10L", "v32L", laneBits: 2 * bits),
        .lower("vC", "v10U", "v32U", laneBits: 2 * bits),
        .upper("vD", "v10U", "v32U", laneBits: 2 * bits),
    ]
}

func x86LoadInterleaved3Steps() -> [ShuffleStep] {
    [
        .oddEven("vxx0203xx", odd: "vC", even: "vB", laneBits: 32),
        .floating("r0", "vA", "vxx0203xx", indices: [0, 3, 6, 5], laneBits: 32),
        .oddEven("vxxxx1011", odd: "vA", even: "vB", laneBits: 32),
        .oddEven("v1213xxxx", odd: "vB", even: "vC", laneBits: 32),
        .floating("r1", "vxxxx1011", "v1213xxxx", indices: [1, 0, 7, 6], laneBits: 32),
        .oddEven("vxx2021xx", odd: "vB", even: "vA", laneBits: 32),
        .floating("r2", "vxx2021xx", "vC", indices: [2, 1, 4, 7], laneBits: 32),
    ]
}

func x86StoreInterleaved3Steps() -> [ShuffleStep] {
    [
        .lower("v10v00", "a", "b", laneBits: 32),
        .oddEven("v01v20", odd: "a", even: "c", laneBits: 32),
        .lower("vA", "v10v00", "v01v20", laneBits: 64),
        .shiftedRight("v1x321", "b", lanes: 1, laneBits: 32),
        .shiftedRight("v0x32", "a", lanes: 2, laneBits: 32),
        .oddEven("v21v11", odd: "c", even: "v1x321", laneBits: 32),
        .oddEven("v12v02", odd: "v1x321", even: "v0x32", laneBits: 32),
        .lower("vB", "v21v11", "v12v02", laneBits: 64),
        .upper("vC", "v01v20", "v21v11", laneBits: 64),
    ]
}

func x86LoadInterleaved(
    _ steps: [ShuffleStep],
    channels: Int,
    for element: Element
) -> String {
    let names = ["vA", "vB", "vC", "vD"].prefix(channels)
    let declaration = "\(x86Vector("i\(element.bits)")) \(names.joined(separator: ", "));"
    let loads = names.enumerated().map { index, name in
        "__builtin_memcpy(&\(name), from + \(index * element.laneCount), sizeof \(name));"
    }
    let shuffles = steps.flatMap { step in
        let store = "*v\(step.name.dropFirst()) = (\(element.cVector))\(step.name);"
        return x86Shuffles([step], for: element) + (step.name.hasPrefix("r") ? [store] : [])
    }
    return ([declaration] + loads + shuffles).joined(separator: "\n")
}

func x86StoreInterleaved(
    _ steps: [ShuffleStep],
    channels: Int,
    for element: Element
) -> String {
    let stores = ["vA", "vB", "vC", "vD"].prefix(channels).enumerated().map { index, name in
        "__builtin_memcpy(to + \(index * element.laneCount), &\(name), sizeof \(name));"
    }
    return (x86Shuffles(steps, for: element) + stores).joined(separator: "\n")
}

func x86LoadInterleaved2Bytes(for element: Element) -> String {
    let mask = splat("255", as: x86Vector("i16"), lanes: 8)
    let evens = x86Builtin(
        "packuswb128",
        ["(firstWords & \(mask))", "(secondWords & \(mask))"],
        as: "i16",
        returning: element.cVector
    )
    let odds = x86Builtin(
        "packuswb128",
        ["(firstWords >> 8)", "(secondWords >> 8)"],
        as: "i16",
        returning: element.cVector
    )
    return """
        typedef uint16_t word_vector __attribute__((vector_size(16)));
        \(element.cVector) first, second;
        __builtin_memcpy(&first, from, sizeof first);
        __builtin_memcpy(&second, from + 16, sizeof second);
        const word_vector firstWords = (word_vector)first;
        const word_vector secondWords = (word_vector)second;
        *v0 = \(evens);
        *v1 = \(odds);
        """
}

func x86LoadInterleaved3Gathers(for element: Element) -> String {
    let type = x86Vector("i8")
    let blocks = ["vA", "vB", "vC"]
    let laneBytes = element.bits / 8
    let blockLanes = 16 / laneBytes
    let loads = blocks.enumerated().map { index, name in
        "__builtin_memcpy(&\(name), from + \(blockLanes * index), sizeof \(name));"
    }
    let gathers = (0..<3).map { channel in
        let parts = blocks.enumerated().map { block, name in
            let indices = (0..<16).map { byte -> String in
                let position = 3 * (byte / laneBytes) + channel
                guard position / blockLanes == block else { return "-128" }
                return String((position % blockLanes) * laneBytes + byte % laneBytes)
            }
            let table = compoundLiteral(type, indices)
            return x86Builtin("pshufb128", [name, table], as: "i8", returning: type)
        }
        return "*v\(channel) = (\(element.cVector))(\(parts.joined(separator: " ^ ")));"
    }
    let declaration = "\(type) \(blocks.joined(separator: ", "));"
    return ([declaration] + loads + gathers).joined(separator: "\n")
}

func x86StoreInterleaved3Bytes(for element: Element) -> String {
    let type = element.cVector
    let gathers = ["vA", "vB", "vC"].enumerated().map { block, name in
        let sources = ["a", "b", "c"].enumerated().map { channel, input in
            let positions = (0..<16).map { 16 * block + $0 }
            let indices = positions.map { $0 % 3 == channel ? String($0 / 3) : "0" }
            let kept = positions.map { $0 % 3 == channel ? "-1" : "0" }
            let mask = "(\(type))\(compoundLiteral(x86Vector("i8"), kept))"
            let lanes = indices.joined(separator: ", ")
            return "(__builtin_shufflevector(\(input), \(input), \(lanes)) & \(mask))"
        }
        return "const \(type) \(name) = \(sources.joined(separator: " | "));"
    }
    let stores = ["vA", "vB", "vC"].enumerated().map { block, name in
        "__builtin_memcpy(to + \(16 * block), &\(name), sizeof \(name));"
    }
    return (gathers + stores).joined(separator: "\n")
}

func laneIndices(_ indices: [Int]) -> String {
    indices.map(String.init).joined(separator: ", ")
}

func laneIndices(_ ranges: Range<Int>...) -> String {
    laneIndices(ranges.flatMap { $0 })
}

func unpackIndices(lanes: Int, upper: Bool) -> [Int] {
    let start = upper ? lanes / 2 : 0
    return (start..<start + lanes / 2).flatMap { [$0, $0 + lanes] }
}

func indented(_ code: String) -> String {
    code.split(separator: "\n", omittingEmptySubsequences: false)
        .map { $0.isEmpty ? "" : "  \($0)" }
        .joined(separator: "\n")
}

enum LaneInsertion {
    case lane
    case unpack
}

func loadFirst(for element: Element, inserting insertion: LaneInsertion) -> String {
    loadFirstTree(lanes: element.laneCount, of: element, in: element, inserting: insertion) {
        "return \($0);"
    }
}

func loadFirstWidening(
    from narrow: Element,
    to wide: Element,
    inserting insertion: LaneInsertion
) -> String {
    let lanes = laneIndices(0..<wide.laneCount)
    return loadFirstTree(lanes: wide.laneCount, of: narrow, in: narrow, inserting: insertion) {
        let low = "__builtin_shufflevector(\($0), \($0), \(lanes))"
        return "return __builtin_convertvector(\(low), \(wide.cVector));"
    }
}

func trailingLanes(lanes: Int, vector: String, loadPair: String, insertThird: String) -> String {
    """
    const size_t leading = count & \(lanes - 4);
    \(vector) trailing = {0};
    if (count & 2) {
    \(indented(loadPair))
      if (count & 1) {
    \(indented(indented(insertThird)))
      }
    } else if (count & 1) {
      trailing[0] = from[leading];
    }
    """
}

func loadFirstWords(
    lanes: Int,
    of element: Element,
    in register: Element
) -> (full: String, partial: String) {
    let size = "sizeof(\(element.cType))"
    let full = "__builtin_memcpy(&v, from, \(lanes) * \(size));"
    switch lanes {
    case 2:
        return (full, "__builtin_memcpy(&v, from, \(size));")
    case 4:
        let partial = """
            __builtin_memcpy(&v, from, 2 * \(size));
            if (count != 2) {
              v[2] = from[2];
            }
            """
        return (full, partial)
    default:
        let trailing = trailingLanes(
            lanes: lanes,
            vector: register.cVector,
            loadPair: "__builtin_memcpy(&trailing, from + leading, 2 * \(size));",
            insertThird: "trailing[2] = from[leading + 2];"
        )
        let end = register.laneCount
        let indices = laneIndices(0..<4, end..<end + 4, 8..<end)
        let partial = """
            \(trailing)
            if (leading != 0) {
              __builtin_memcpy(&v, from, 4 * \(size));
              v = __builtin_shufflevector(v, trailing, \(indices));
            } else {
              v = trailing;
            }
            """
        return (full, partial)
    }
}

func loadFirstBytes(
    lanes: Int,
    in vector: String,
    inserting insertion: LaneInsertion
) -> (typedefs: [String], full: String, partial: String) {
    let words = laneIndices(unpackIndices(lanes: 4, upper: false))
    let typedefs = [
        "typedef uint32_t word_vector __attribute__((vector_size(16)));",
        lanes == 16 ? "typedef uint64_t long_vector __attribute__((vector_size(16)));" : "",
        lanes > 4 && insertion == .unpack
            ? "typedef uint16_t half_vector __attribute__((vector_size(16)));" : "",
    ].filter { !$0.isEmpty }
    func loadPair(into target: String, at offset: String) -> String {
        """
        uint16_t pair;
        __builtin_memcpy(&pair, from + \(offset), sizeof pair);
        \(target) = (\(vector))(word_vector){pair, 0, 0, 0};
        """
    }
    func insertThird(into target: String, at index: String) -> String {
        switch (insertion, lanes) {
        case (.lane, _):
            return "\(target)[2] = from[\(index)];"
        case (.unpack, 4):
            return "\(target) |= (\(vector)){0, 0, from[\(index)]};"
        case (.unpack, _):
            let halves = laneIndices(unpackIndices(lanes: 8, upper: false))
            return """
                const word_vector third = {(uint8_t)from[\(index)], 0, 0, 0};
                \(target) = (\(vector))__builtin_shufflevector(
                  (half_vector)\(target), (half_vector)third, \(halves));
                """
        }
    }
    let full = lanes == 2 ? loadPair(into: "v", at: "0") : "__builtin_memcpy(&v, from, \(lanes));"
    let trailing = trailingLanes(
        lanes: lanes,
        vector: vector,
        loadPair: loadPair(into: "trailing", at: "leading"),
        insertThird: insertThird(into: "trailing", at: "leading + 2")
    )
    let head = """
        uint32_t head;
        __builtin_memcpy(&head, from, sizeof head);
        v = (\(vector))__builtin_shufflevector(
          (word_vector){head, 0, 0, 0}, (word_vector)trailing, \(words));
        """
    switch lanes {
    case 2:
        return (typedefs, full, "__builtin_memcpy(&v, from, 1);")
    case 4:
        let partial = """
            \(loadPair(into: "v", at: "0"))
            if (count != 2) {
            \(indented(insertThird(into: "v", at: "2")))
            }
            """
        return (typedefs, full, partial)
    case 8:
        let partial = """
            \(trailing)
            if (leading != 0) {
            \(indented(head))
            } else {
              v = trailing;
            }
            """
        return (typedefs, full, partial)
    default:
        let longs = laneIndices(unpackIndices(lanes: 2, upper: false))
        let partial = """
            \(trailing)
            if (leading == 0) {
              v = trailing;
            } else if (leading < 8) {
            \(indented(head))
            } else {
              word_vector upper = (word_vector)trailing;
              if (leading & 4) {
                uint32_t middle;
                __builtin_memcpy(&middle, from + 8, sizeof middle);
                upper = __builtin_shufflevector(
                  (word_vector){middle, 0, 0, 0}, upper, \(words));
              }
              uint64_t first;
              __builtin_memcpy(&first, from, sizeof first);
              v = (\(vector))__builtin_shufflevector(
                (long_vector){first, 0}, (long_vector)upper, \(longs));
            }
            """
        return (typedefs, full, partial)
    }
}

func loadFirstTree(
    lanes: Int,
    of element: Element,
    in register: Element,
    inserting insertion: LaneInsertion,
    returning finish: (String) -> String
) -> String {
    let vector = register.cVector
    let single = "__builtin_memcpy(&v, from, sizeof(\(element.cType)));"
    let parts: (typedefs: [String], full: String, partial: String)
    if element.bits == 8 {
        parts = loadFirstBytes(lanes: lanes, in: vector, inserting: insertion)
    } else {
        let words = loadFirstWords(lanes: lanes, of: element, in: register)
        parts = ([], words.full, words.partial)
    }
    var lines = parts.typedefs + ["\(vector) v = {0};"]
    lines += ["if (count >= \(lanes)) {", indented(parts.full), "} else if (count == 0) {"]
    if lanes > 2 {
        lines += ["} else if (count == 1) {", indented(single)]
    }
    lines += ["} else {", indented(parts.partial), "}", finish("v")]
    return lines.joined(separator: "\n")
}

func storeLanes(
    _ lanes: Int,
    of vector: String,
    at lane: Int,
    to destination: Int,
    for element: Element
) -> String {
    let bits = lanes * element.bits
    guard bits < 128 else {
        return "__builtin_memcpy(to + \(destination), &\(vector), sizeof \(vector));"
    }
    let chunkType = lanes == 1 ? element.cType : "uint\(bits)_t"
    return """
        {
          typedef \(chunkType) chunk_vector __attribute__((vector_size(16)));
          const \(chunkType) chunk = ((chunk_vector)\(vector))[\(lane * element.bits / bits)];
          __builtin_memcpy(to + \(destination), &chunk, sizeof chunk);
        }
        """
}

func upperHalf(of vector: String, lanes: Int, for element: Element) -> String {
    let indices = (0..<element.laneCount).map { ($0 + lanes / 2) % element.laneCount }
    return "__builtin_shufflevector(\(vector), \(vector), \(laneIndices(indices)))"
}

func storeFirstTree(
    lanes: Int,
    of vector: String,
    to destination: Int,
    count: String,
    for element: Element
) -> String {
    func store(_ lanes: Int, at lane: Int) -> String {
        storeLanes(lanes, of: vector, at: lane, to: destination + lane, for: element)
    }
    let one = indented(store(1, at: 0))
    switch lanes {
    case 2:
        return """
            if (\(count) > 1) {
            \(indented(store(2, at: 0)))
            } else if (\(count) == 1) {
            \(one)
            }
            """
    case 4:
        return """
            if (\(count) > 1) {
              if (\(count) >= 4) {
            \(indented(indented(store(4, at: 0))))
              } else {
            \(indented(indented(store(2, at: 0))))
                if (\(count) == 3) {
            \(indented(indented(indented(store(1, at: 2)))))
                }
              }
            } else if (\(count) == 1) {
            \(one)
            }
            """
    default:
        let half = lanes / 2
        let upper = "upper\(half)"
        let upperTree = storeFirstTree(
            lanes: half,
            of: upper,
            to: destination + half,
            count: "(\(count) - \(half))",
            for: element
        )
        let lowerTree = storeFirstTree(
            lanes: half,
            of: vector,
            to: destination,
            count: count,
            for: element
        )
        let upperVector = upperHalf(of: vector, lanes: lanes, for: element)
        return """
            if (\(count) <= 1) {
              if (\(count) == 1) {
            \(indented(one))
              }
            } else if (\(count) >= \(lanes)) {
            \(indented(store(lanes, at: 0)))
            } else if (\(count) >= \(half)) {
            \(indented(store(half, at: 0)))
              const \(element.cVector) \(upper) = \(upperVector);
            \(indented(upperTree))
            } else {
            \(indented(lowerTree))
            }
            """
    }
}

func storeFirst(for element: Element) -> String {
    storeFirstTree(lanes: element.laneCount, of: "a", to: 0, count: "count", for: element)
}

func shuffleLoadInterleaved(channels: Int, for element: Element) -> String {
    let lanes = element.laneCount
    let splits = (0..<channels).map { channel in
        let indices = laneIndices((0..<lanes).map { channels * $0 + channel })
        return "*v\(channel) = (\(element.cVector))__builtin_shufflevector(all, all, \(indices));"
    }
    return """
        typedef \(element.cUnsignedLane) wide_vector __attribute__((vector_size(\(16 * channels))));
        wide_vector all;
        __builtin_memcpy(&all, from, \(16 * channels));
        \(splits.joined(separator: "\n"))
        """
}

func shuffleStoreInterleaved(channels: Int, for element: Element) -> String {
    let lanes = element.laneCount
    let type = element.cUnsignedLane
    let inputs = ["a", "b", "c", "d"].prefix(channels).map { unsignedBits($0, of: element) }
    let both = laneIndices(0..<2 * lanes)
    let single = laneIndices(Array(0..<lanes) + Array(repeating: -1, count: lanes))
    let interleaved = laneIndices(
        (0..<lanes).flatMap { lane in (0..<channels).map { $0 * lanes + lane } }
    )
    let wide = "typedef \(type) wide_vector __attribute__((vector_size(\(16 * channels))));"
    let pair = "typedef \(type) pair_vector __attribute__((vector_size(32)));"
    let shuffle = "__builtin_shufflevector"
    var statements: [String]
    let operands: String
    switch channels {
    case 2:
        statements = [wide]
        operands = "\(inputs[0]), \(inputs[1])"
    case 3:
        statements = [
            pair, wide,
            "const pair_vector ab = \(shuffle)(\(inputs[0]), \(inputs[1]), \(both));",
            "const pair_vector cc = \(shuffle)(\(inputs[2]), \(inputs[2]), \(single));",
        ]
        operands = "ab, cc"
    default:
        statements = [
            pair, wide,
            "const pair_vector ab = \(shuffle)(\(inputs[0]), \(inputs[1]), \(both));",
            "const pair_vector cd = \(shuffle)(\(inputs[2]), \(inputs[3]), \(both));",
        ]
        operands = "ab, cd"
    }
    statements.append("const wide_vector all = \(shuffle)(\(operands), \(interleaved));")
    statements.append("__builtin_memcpy(to, &all, \(16 * channels));")
    return statements.joined(separator: "\n")
}

let ops: [Op] = [
    Op("zero", "Zero", [.tag], .vector, .all) { element in
        "return \(compoundLiteral(element.cVector, ["0"]));"
    },
    Op("repeating", "Set", [.tag, .lane], .vector, .all) { element in
        "return \(splat("value", as: element.cVector, lanes: element.laneCount));"
    },
    Op("iota", "Iota", [.tag, .lane], .vector, .all) { element in
        let lanes = element.laneCount
        switch element.category {
        case .unsignedInteger, .float:
            let first = splat("value", as: element.cVector, lanes: lanes)
            return "return \(first) + \(iota(as: element.cVector, lanes: lanes));"
        case .signedInteger:
            let type = element.cUnsignedVector
            let first = splat("(\(element.cUnsignedLane))value", as: type, lanes: lanes)
            return "return (\(element.cVector))(\(first) + \(iota(as: type, lanes: lanes)));"
        }
    },

    Op("load", "LoadU", [.tag, .constLanePointer], .vector, .all, span: .vectors(1)) { element in
        """
        \(element.cVector) v;
        __builtin_memcpy(&v, from, sizeof v);
        return v;
        """
    },
    Op(
        "loadAligned",
        "Load",
        [.tag, .constLanePointer],
        .vector,
        .all,
        span: .vectors(1, aligned: true)
    ) { element in
        """
        \(element.cVector) v;
        __builtin_memcpy(&v, __builtin_assume_aligned(from, 16), sizeof v);
        return v;
        """
    },
    Op(
        "loadFirst",
        "LoadN",
        [.tag, .constLanePointer, .count],
        .vector,
        .all,
        span: .first,
        targets: TargetBodies(
            neon: { element in loadFirst(for: element, inserting: .lane) },
            sse4: { element in loadFirst(for: element, inserting: .lane) },
            sse2: { element in loadFirst(for: element, inserting: .unpack) }
        )
    ) { element in
        let size = "\(clampedCount(to: element.laneCount)) * sizeof(\(element.cType))"
        return """
            \(element.cVector) v = {0};
            __builtin_memcpy(&v, from, \(size));
            return v;
            """
    },
    Op("store", "StoreU", [.vector, .tag, .lanePointer], .void, .all, span: .vectors(1)) { _ in
        "__builtin_memcpy(to, &a, sizeof a);"
    },
    Op(
        "storeAligned",
        "Store",
        [.vector, .tag, .lanePointer],
        .void,
        .all,
        span: .vectors(1, aligned: true)
    ) { _ in
        "__builtin_memcpy(__builtin_assume_aligned(to, 16), &a, sizeof a);"
    },
    Op(
        "storeFirst",
        "StoreN",
        [.vector, .tag, .lanePointer, .count],
        .void,
        .all,
        span: .first,
        targets: TargetBodies(
            neon: { element in storeFirst(for: element) },
            sse2: { element in storeFirst(for: element) }
        )
    ) { element in
        let size = "\(clampedCount(to: element.laneCount)) * sizeof(\(element.cType))"
        return "__builtin_memcpy(to, &a, \(size));"
    },

    Op("adding", "Add", [.vector, .vector], .vector, .all) { element in
        binaryArithmetic("+", for: element)
    },
    Op("subtracting", "Sub", [.vector, .vector], .vector, .all) { element in
        binaryArithmetic("-", for: element)
    },
    Op(
        "multiplying",
        "Mul",
        [.vector, .vector],
        .vector,
        .all(bits: [16, 32, 64]),
        targets: TargetBodies(
            sse4: { element in
                isInteger32(element) ? binaryArithmetic("*", for: element) : nil
            },
            sse2: { element in isInteger32(element) ? x86Multiplying32(for: element) : nil }
        )
    ) { element in
        binaryArithmetic("*", for: element)
    },
    Op(
        "dividing",
        "Div",
        [.vector, .vector],
        .vector,
        .float,
        targets: TargetBodies(
            neon: { _ in "return a / b;" },
            sse2: { _ in "return a / b;" }
        )
    ) { element in
        let zero = compoundLiteral(element.cVector, ["0"])
        let nonZero = "(\(element.cUnsignedVector))(b != \(zero))"
        let quotient = unsignedBits("(a / b)", of: element)
        return "return \(fromUnsignedBits("\(nonZero) & \(quotient)", of: element));"
    },
    Op(
        "minimum",
        "Min",
        [.vector, .vector],
        .vector,
        .all,
        targets: TargetBodies(
            neon: { element in
                guard element.category == .float else { return nil }
                let code = neonTypeCode(of: element)
                return "return \(neonBuiltin("vminnmq_v", ["a", "b"], code: code, for: element));"
            },
            sse4: { element in
                isSignedInteger64(element)
                    ? x86Int64Extremum(("a", "b"), native: true, for: element) : nil
            },
            sse2: { element in
                if isSignedInteger64(element) {
                    return x86Int64Extremum(("a", "b"), for: element)
                }
                return element.category == .float
                    ? "return \(x86Extremum("min", "a", "b", for: element));" : nil
            }
        )
    ) { element in
        elementwiseExtremum("min", comparing: "<", for: element)
    },
    Op(
        "maximum",
        "Max",
        [.vector, .vector],
        .vector,
        .all,
        targets: TargetBodies(
            neon: { element in
                guard element.category == .float else { return nil }
                let code = neonTypeCode(of: element)
                return "return \(neonBuiltin("vmaxnmq_v", ["a", "b"], code: code, for: element));"
            },
            sse4: { element in
                isSignedInteger64(element)
                    ? x86Int64Extremum(("b", "a"), native: true, for: element) : nil
            },
            sse2: { element in
                if isSignedInteger64(element) {
                    return x86Int64Extremum(("b", "a"), for: element)
                }
                return element.category == .float
                    ? "return \(x86Extremum("max", "a", "b", for: element));" : nil
            }
        )
    ) { element in
        elementwiseExtremum("max", comparing: ">", for: element)
    },
    Op("negated", "Neg", [.vector], .vector, .signedOrFloat) { element in
        guard element.category == .signedInteger else { return "return -a;" }
        let zero = compoundLiteral(element.cUnsignedVector, ["0"])
        return "return (\(element.cVector))(\(zero) - (\(element.cUnsignedVector))a);"
    },
    Op("magnitude", "Abs", [.vector], .vector, .signedOrFloat) { _ in
        "return __builtin_elementwise_abs(a);"
    },
    Op("squareRoot", "Sqrt", [.vector], .vector, .float) { _ in
        "return __builtin_elementwise_sqrt(a);"
    },
    Op(
        "multiplyAdding",
        "MulAdd",
        [.vector, .vector, .vector],
        .vector,
        .float,
        targets: TargetBodies(neon: { _ in "return __builtin_elementwise_fma(a, b, c);" })
    ) { _ in
        """
        #pragma clang fp contract(off)
        return a * b + c;
        """
    },
    Op(
        "saturatingAdding",
        "SaturatedAdd",
        [.vector, .vector],
        .vector,
        .integer(bits: [8, 16])
    ) { _ in
        "return __builtin_elementwise_add_sat(a, b);"
    },
    Op(
        "saturatingSubtracting",
        "SaturatedSub",
        [.vector, .vector],
        .vector,
        .integer(bits: [8, 16])
    ) { _ in
        "return __builtin_elementwise_sub_sat(a, b);"
    },
    Op(
        "roundedAverage",
        "AverageRound",
        [.vector, .vector],
        .vector,
        .unsigned(bits: [8, 16])
    ) { _ in
        "return (a | b) - ((a ^ b) >> 1);"
    },

    Op("bitwiseAnd", "And", [.vector, .vector], .vector, .integer) { _ in
        "return a & b;"
    },
    Op("bitwiseOr", "Or", [.vector, .vector], .vector, .integer) { _ in
        "return a | b;"
    },
    Op("bitwiseXor", "Xor", [.vector, .vector], .vector, .integer) { _ in
        "return a ^ b;"
    },
    Op("bitwiseNot", "Not", [.vector], .vector, .integer) { _ in
        "return ~a;"
    },
    Op("bitwiseAndNot", "AndNot", [.vector, .vector], .vector, .integer) { _ in
        "return ~a & b;"
    },

    Op(
        "shiftedLeft",
        "ShiftLeftSame",
        [.vector, .shiftAmount],
        .vector,
        .integer,
        targets: TargetBodies(
            neon: { element in neonShift(negated: false, for: element) },
            sse2: { element in x86ShiftedLeft(for: element) }
        )
    ) { element in
        let zero = compoundLiteral(element.cVector, ["0"])
        let shifted = fromUnsignedBits("\(unsignedBits("a", of: element)) << bits", of: element)
        return """
            if (bits < 0 || bits >= \(element.bits)) {
              return \(zero);
            }
            return \(shifted);
            """
    },
    Op(
        "shiftedRight",
        "ShiftRightSame",
        [.vector, .shiftAmount],
        .vector,
        .integer,
        targets: TargetBodies(
            neon: { element in neonShift(negated: true, for: element) },
            sse2: { element in x86ShiftedRight(for: element) }
        )
    ) { element in
        let outOfRange =
            element.category == .signedInteger
            ? "bits = \(element.bits - 1);"
            : "return \(compoundLiteral(element.cVector, ["0"]));"
        return """
            if (bits < 0 || bits >= \(element.bits)) {
              \(outOfRange)
            }
            return a >> bits;
            """
    },

    Op("equalTo", "Eq", [.vector, .vector], .mask, .all) { element in
        "return (\(element.cMask))(a == b);"
    },
    Op("notEqualTo", "Ne", [.vector, .vector], .mask, .all) { element in
        "return (\(element.cMask))(a != b);"
    },
    Op(
        "lessThan",
        "Lt",
        [.vector, .vector],
        .mask,
        .all,
        targets: TargetBodies(
            sse4: { element in
                isSignedInteger64(element) ? vectorComparison("<", for: element) : nil
            },
            sse2: { element in
                isSignedInteger64(element)
                    ? "\(x86Int64Greater("b", "a", for: element))\nreturn mask;" : nil
            }
        )
    ) { element in
        vectorComparison("<", for: element)
    },
    Op(
        "greaterThan",
        "Gt",
        [.vector, .vector],
        .mask,
        .all,
        targets: TargetBodies(
            sse4: { element in
                isSignedInteger64(element) ? vectorComparison(">", for: element) : nil
            },
            sse2: { element in
                isSignedInteger64(element)
                    ? "\(x86Int64Greater("a", "b", for: element))\nreturn mask;" : nil
            }
        )
    ) { element in
        vectorComparison(">", for: element)
    },

    Op(
        "selecting",
        "IfThenElse",
        [.mask, .vector, .vector],
        .vector,
        .all,
        targets: TargetBodies(sse4: { element in "return \(x86Selecting(for: element));" })
    ) { element in
        "return \(bitSelect("mask", "a", "b", of: element));"
    },
    Op("selectingOrZero", "IfThenElseZero", [.mask, .vector], .vector, .all) { element in
        let mask = "(\(element.cUnsignedVector))mask"
        let selected = fromUnsignedBits("\(mask) & \(unsignedBits("a", of: element))", of: element)
        return "return \(selected);"
    },
    Op("zeroingSelected", "IfThenZeroElse", [.mask, .vector], .vector, .all) { element in
        let mask = "(\(element.cUnsignedVector))mask"
        let kept = fromUnsignedBits("~\(mask) & \(unsignedBits("a", of: element))", of: element)
        return "return \(kept);"
    },
    Op("firstLanes", "FirstN", [.tag, .count], .mask, .all) { element in
        let lanes = element.laneCount
        let offsets = iota(as: element.cUnsignedVector, lanes: lanes)
        let limit = splat("n", as: element.cUnsignedVector, lanes: lanes)
        return """
            const \(element.cUnsignedLane) n = (\(element.cUnsignedLane))\(clampedCount(to: lanes));
            return (\(element.cMask))(\(offsets) < \(limit));
            """
    },
    Op(
        "allTrue",
        "AllTrue",
        [.tag, .mask],
        .boolean,
        .all,
        targets: TargetBodies(
            neon: { _ in "\(neonNibbles)\nreturn nibbles == ~0ull;" },
            sse2: { element in x86AllTrue(for: element) }
        )
    ) { _ in
        "return __builtin_reduce_and(mask) != 0;"
    },
    Op(
        "allFalse",
        "AllFalse",
        [.tag, .mask],
        .boolean,
        .all,
        targets: TargetBodies(
            neon: { _ in "\(neonNibbles)\nreturn nibbles == 0;" },
            sse2: { element in "return \(x86MaskBits(for: element)) == 0;" }
        )
    ) { _ in
        "return __builtin_reduce_or(mask) == 0;"
    },
    Op(
        "trueCount",
        "CountTrue",
        [.tag, .mask],
        .count,
        .all,
        targets: TargetBodies(
            neon: { _ in "return (size_t)__builtin_reduce_add(-mask);" },
            sse2: { element in
                "return (size_t)__builtin_popcountll((uint64_t)(unsigned)\(x86MaskBits(for: element)));"
            }
        )
    ) { _ in
        "return (size_t)-__builtin_reduce_add(mask);"
    },
    Op(
        "firstTrueIndex",
        "FindFirstTrue",
        [.tag, .mask],
        .index,
        .all,
        targets: TargetBodies(
            neon: { element in neonFirstTrueIndex(for: element) },
            sse2: { element in x86FirstTrueIndex(for: element) }
        )
    ) { element in
        """
        for (size_t i = 0; i < \(element.laneCount); ++i) {
          if (mask[i]) {
            return (intptr_t)i;
          }
        }
        return -1;
        """
    },

    Op(
        "sum",
        "ReduceSum",
        [.tag, .vector],
        .lane,
        .all(bits: [16, 32, 64]),
        targets: TargetBodies(
            neon: { element in neonReduction("vaddvq", for: element) },
            sse2: { element in x86Reduction(for: element) { "\($0) + \($1)" } }
        )
    ) { element in
        guard element.category == .float else { return "return __builtin_reduce_add(a);" }
        return """
            \(element.cType) sum = 0;
            for (size_t i = 0; i < \(element.laneCount); ++i) {
              sum += a[i];
            }
            return sum;
            """
    },
    Op(
        "smallest",
        "ReduceMin",
        [.tag, .vector],
        .lane,
        .all(bits: [16, 32, 64]),
        targets: TargetBodies(
            neon: { element in neonReduction("vminvq", for: element) },
            sse4: { element in
                isSignedInteger64(element)
                    ? x86Int64Reduction(("a", "reversed"), native: true, for: element) : nil
            },
            sse2: { element in
                if isSignedInteger64(element) {
                    return x86Int64Reduction(("a", "reversed"), for: element)
                }
                return x86Reduction(for: element) { x86Extremum("min", $0, $1, for: element) }
            }
        )
    ) { element in
        reducedExtremum("min", comparing: "<", from: infinity(of: element), for: element)
    },
    Op(
        "largest",
        "ReduceMax",
        [.tag, .vector],
        .lane,
        .all(bits: [16, 32, 64]),
        targets: TargetBodies(
            neon: { element in neonReduction("vmaxvq", for: element) },
            sse4: { element in
                isSignedInteger64(element)
                    ? x86Int64Reduction(("reversed", "a"), native: true, for: element) : nil
            },
            sse2: { element in
                if isSignedInteger64(element) {
                    return x86Int64Reduction(("reversed", "a"), for: element)
                }
                return x86Reduction(for: element) { x86Extremum("max", $0, $1, for: element) }
            }
        )
    ) { element in
        reducedExtremum("max", comparing: ">", from: "-\(infinity(of: element))", for: element)
    },
    Op("firstLane", "GetLane", [.vector], .lane, .all) { _ in
        "return a[0];"
    },

    Op("reversed", "Reverse", [.tag, .vector], .vector, .all) { element in
        let indices = (0..<element.laneCount).reversed().map(String.init)
        return "return __builtin_shufflevector(a, a, \(indices.joined(separator: ", ")));"
    },
    Op(
        "slideUpLanes",
        "SlideUpLanes",
        [.tag, .vector, .laneAmount],
        .vector,
        .all,
        targets: TargetBodies(
            neon: { element in
                """
                \(slideUpConstants(for: element))
                \(slideUpIndices(for: element))
                return \(neonTableLookup("a", "indices", for: element));
                """
            },
            ssse3: { element in
                """
                \(slideUpConstants(for: element))
                \(slideUpIndices(for: element))
                return \(x86TableLookup("a", "indices", for: element));
                """
            },
            sse2: { element in
                """
                \(slideUpConstants(for: element))
                \(x86SlideUp(for: element))
                """
            }
        )
    ) { element in
        """
        \(element.cVector) result = {0};
        for (size_t i = lanes; i < \(element.laneCount); ++i) {
          result[i] = a[i - lanes];
        }
        return result;
        """
    },
    Op(
        "slide1Up",
        "Slide1Up",
        [.tag, .vector],
        .vector,
        .all,
        targets: TargetBodies(
            neon: { element in neonSlide1Up(for: element) },
            ssse3: { element in isFloat32(element) ? x86Slide1UpFloat(for: element) : nil }
        )
    ) { element in
        let lanes = element.laneCount
        let indices = ([lanes] + Array(0..<(lanes - 1))).map(String.init)
        let zero = compoundLiteral(element.cVector, ["0"])
        return "return __builtin_shufflevector(a, \(zero), \(indices.joined(separator: ", ")));"
    },
    Op(
        "tableLookupBytes",
        "TableLookupBytes",
        [.vector, .indices],
        .vector,
        .integer(bits: [8]),
        targets: TargetBodies(
            neon: { element in "return \(neonTableLookup("a", "b", for: element));" },
            ssse3: { element in "return \(x86TableLookup("a", "b", for: element));" },
            sse2: { element in
                """
                uint8_t table[16];
                uint8_t indices[16];
                uint8_t looked_up[16];
                \(element.cVector) result;
                __builtin_memcpy(table, &a, sizeof table);
                __builtin_memcpy(indices, &b, sizeof indices);
                for (size_t i = 0; i < 16; ++i) {
                  looked_up[i] = table[indices[i] & 15];
                }
                __builtin_memcpy(&result, looked_up, sizeof result);
                return result;
                """
            }
        )
    ) { element in
        """
        \(element.cVector) result;
        for (size_t i = 0; i < 16; ++i) {
          const uint8_t index = (uint8_t)b[i];
          result[i] = index < 16 ? a[index] : 0;
        }
        return result;
        """
    },

    Op(
        "loadInterleaved2",
        "LoadInterleaved2",
        [.tag, .constLanePointer, .outVector, .outVector],
        .void,
        .all,
        span: .vectors(2),
        targets: TargetBodies(
            neon: { element in shuffleLoadInterleaved(channels: 2, for: element) },
            sse2: { element in
                element.bits == 8
                    ? x86LoadInterleaved2Bytes(for: element)
                    : shuffleLoadInterleaved(channels: 2, for: element)
            }
        )
    ) { element in
        loadInterleaved(channels: 2, for: element)
    },
    Op(
        "loadInterleaved3",
        "LoadInterleaved3",
        [.tag, .constLanePointer, .outVector, .outVector, .outVector],
        .void,
        .all,
        span: .vectors(3),
        targets: TargetBodies(
            neon: { element in shuffleLoadInterleaved(channels: 3, for: element) },
            ssse3: { element in
                element.bits <= 16 ? x86LoadInterleaved3Gathers(for: element) : nil
            },
            sse2: { element in
                element.bits == 32
                    ? x86LoadInterleaved(x86LoadInterleaved3Steps(), channels: 3, for: element)
                    : shuffleLoadInterleaved(channels: 3, for: element)
            }
        )
    ) { element in
        loadInterleaved(channels: 3, for: element)
    },
    Op(
        "loadInterleaved4",
        "LoadInterleaved4",
        [.tag, .constLanePointer, .outVector, .outVector, .outVector, .outVector],
        .void,
        .all,
        span: .vectors(4),
        targets: TargetBodies(
            neon: { element in shuffleLoadInterleaved(channels: 4, for: element) },
            sse2: { element in
                x86LoadInterleaved(
                    x86LoadInterleaved4Steps(for: element),
                    channels: 4,
                    for: element
                )
            }
        )
    ) { element in
        loadInterleaved(channels: 4, for: element)
    },
    Op(
        "storeInterleaved2",
        "StoreInterleaved2",
        [.vector, .vector, .tag, .lanePointer],
        .void,
        .all,
        span: .vectors(2),
        targets: TargetBodies(
            neon: { element in shuffleStoreInterleaved(channels: 2, for: element) },
            sse2: { element in shuffleStoreInterleaved(channels: 2, for: element) }
        )
    ) { element in
        storeInterleaved(channels: 2, for: element)
    },
    Op(
        "storeInterleaved3",
        "StoreInterleaved3",
        [.vector, .vector, .vector, .tag, .lanePointer],
        .void,
        .all,
        span: .vectors(3),
        targets: TargetBodies(
            neon: { element in shuffleStoreInterleaved(channels: 3, for: element) },
            ssse3: { element in
                element.bits == 8 ? shuffleStoreInterleaved(channels: 3, for: element) : nil
            },
            sse2: { element in
                switch element.bits {
                case 8: return x86StoreInterleaved3Bytes(for: element)
                case 32:
                    return x86StoreInterleaved(
                        x86StoreInterleaved3Steps(),
                        channels: 3,
                        for: element
                    )
                default: return shuffleStoreInterleaved(channels: 3, for: element)
                }
            }
        )
    ) { element in
        storeInterleaved(channels: 3, for: element)
    },
    Op(
        "storeInterleaved4",
        "StoreInterleaved4",
        [.vector, .vector, .vector, .vector, .tag, .lanePointer],
        .void,
        .all,
        span: .vectors(4),
        targets: TargetBodies(
            neon: { element in shuffleStoreInterleaved(channels: 4, for: element) },
            sse2: { element in
                x86StoreInterleaved(
                    x86StoreInterleaved4Steps(for: element),
                    channels: 4,
                    for: element
                )
            }
        )
    ) { element in
        storeInterleaved(channels: 4, for: element)
    },
]

// A widening load reads lanes of a narrower element type and promotes each of them to the
// element type of the vector it returns. It is two Highway ops rather than one, and its pointer
// is not a `Lane` pointer, so it does not fit `Op` and is generated on its own below.
struct WideningOp {
    let swiftName: String
    let highwayName: String
    let takesCount: Bool
    var targets = TargetBodies<(narrow: Element, wide: Element)>()

    var span: SpanExtent { takesCount ? .first : .vectors(1) }
}

let wideningOps: [WideningOp] = [
    WideningOp(
        swiftName: "loadWidening",
        highwayName: "LoadU",
        takesCount: false,
        targets: TargetBodies(
            sse4: { narrow, wide in
                isInt64Widening(from: narrow, to: wide)
                    ? wideningBody(takesCount: false, from: narrow, to: wide) : nil
            },
            sse2: { narrow, wide in
                isInt64Widening(from: narrow, to: wide)
                    ? x86Int64Widening(from: narrow, to: wide) : nil
            }
        )
    ),
    WideningOp(
        swiftName: "loadFirstWidening",
        highwayName: "LoadN",
        takesCount: true,
        targets: TargetBodies(
            neon: { narrow, wide in loadFirstWidening(from: narrow, to: wide, inserting: .lane) },
            sse4: { narrow, wide in loadFirstWidening(from: narrow, to: wide, inserting: .lane) },
            sse2: { narrow, wide in
                isInt64Widening(from: narrow, to: wide)
                    ? x86Int64LoadFirstWidening(from: narrow, to: wide)
                    : loadFirstWidening(from: narrow, to: wide, inserting: .unpack)
            }
        )
    ),
]

/// The element types `element` can be widened from: every narrower one Highway promotes to it,
/// which is every narrower one of the same category.
func wideningSources(of element: Element) -> [Element] {
    elements.filter { $0.category == element.category && $0.bits < element.bits }
}

func wideningFunctionName(_ op: WideningOp, from narrow: Element, to wide: Element) -> String {
    "\(op.swiftName)\(narrow.suffix)To\(wide.suffix)"
}

func snakeCased(_ name: String) -> String {
    name.map { $0.isUppercase ? "_\($0.lowercased())" : String($0) }.joined()
}

func cFunctionName(_ swiftName: String, _ element: Element) -> String {
    "chighway_ops_\(snakeCased(swiftName))_\(element.cSuffix)"
}

func referenceFunctionName(_ name: String, _ element: Element) -> String {
    "\(name)\(element.suffix)"
}

func cWideningFunctionName(_ op: WideningOp, from narrow: Element, to wide: Element) -> String {
    "chighway_ops_\(snakeCased(op.swiftName))_\(narrow.cSuffix)_to_\(wide.cSuffix)"
}

let repeatingBlockName = "repeatingBlock"

/// The parameters of `repeatingBlock`, one per lane of a 128-bit block.
func repeatingBlockLanes(of element: Element) -> [String] {
    (0..<element.laneCount).map { "v\($0)" }
}

struct Binding {
    let declaration: String
    let cDeclaration: String
    let argument: String
    let swiftLabel: String?
    let swiftName: String
    let swiftType: String
    let isInOut: Bool
}

func bindings(of op: Op, for element: Element, scope: String = "") -> [Binding] {
    var vectorNames = ["a", "b", "c", "d"].makeIterator()
    var outVectorIndex = 0
    var result: [Binding] = []

    for parameter in op.parameters {
        switch parameter {
        case .tag:
            result.append(
                Binding(
                    declaration: "",
                    cDeclaration: "",
                    argument: "\(element.tag)()",
                    swiftLabel: nil,
                    swiftName: "",
                    swiftType: "",
                    isInOut: false
                )
            )
        case .vector, .indices:
            let name = vectorNames.next() ?? "v"
            result.append(
                Binding(
                    declaration: "\(element.vector) \(name)",
                    cDeclaration: "\(element.cVector) \(name)",
                    argument: name,
                    swiftLabel: "_",
                    swiftName: name,
                    swiftType: "\(scope)Vector",
                    isInOut: false
                )
            )
        case .mask:
            result.append(
                Binding(
                    declaration: "\(element.mask) mask",
                    cDeclaration: "\(element.cMask) mask",
                    argument: "mask",
                    swiftLabel: "_",
                    swiftName: "mask",
                    swiftType: "\(scope)Mask",
                    isInOut: false
                )
            )
        case .lane:
            result.append(
                Binding(
                    declaration: "\(element.cType) value",
                    cDeclaration: "\(element.cType) value",
                    argument: "value",
                    swiftLabel: "_",
                    swiftName: "value",
                    swiftType: "\(scope)Lane",
                    isInOut: false
                )
            )
        case .constLanePointer:
            result.append(
                Binding(
                    declaration: "const \(element.cType)* from",
                    cDeclaration: "const \(element.cType)* from",
                    argument: "from",
                    swiftLabel: "from",
                    swiftName: "from",
                    swiftType: "UnsafePointer<\(scope)Lane>",
                    isInOut: false
                )
            )
        case .lanePointer:
            result.append(
                Binding(
                    declaration: "\(element.cType)* to",
                    cDeclaration: "\(element.cType)* to",
                    argument: "to",
                    swiftLabel: "to",
                    swiftName: "to",
                    swiftType: "UnsafeMutablePointer<\(scope)Lane>",
                    isInOut: false
                )
            )
        case .count:
            result.append(
                Binding(
                    declaration: "size_t count",
                    cDeclaration: "size_t count",
                    argument: "count",
                    swiftLabel: "count",
                    swiftName: "count",
                    swiftType: "Int",
                    isInOut: false
                )
            )
        case .shiftAmount:
            result.append(
                Binding(
                    declaration: "int bits",
                    cDeclaration: "int bits",
                    argument: "bits",
                    swiftLabel: "by",
                    swiftName: "bits",
                    swiftType: "Int",
                    isInOut: false
                )
            )
        case .laneAmount:
            result.append(
                Binding(
                    declaration: "size_t lanes",
                    cDeclaration: "size_t lanes",
                    argument: "lanes",
                    swiftLabel: "by",
                    swiftName: "lanes",
                    swiftType: "Int",
                    isInOut: false
                )
            )
        case .outVector:
            let name = "v\(outVectorIndex)"
            outVectorIndex += 1
            result.append(
                Binding(
                    declaration: "\(element.vector)& \(name)",
                    cDeclaration: "\(element.cVector)* \(name)",
                    argument: name,
                    swiftLabel: "_",
                    swiftName: name,
                    swiftType: "\(scope)Vector",
                    isInOut: true
                )
            )
        }
    }
    return result
}

func referenceReturnType(_ returns: ReturnType, _ element: Element) -> String {
    switch returns {
    case .vector: return element.vector
    case .mask: return element.mask
    case .lane: return element.cType
    case .count: return "size_t"
    case .index: return "intptr_t"
    case .boolean: return "bool"
    case .void: return "void"
    }
}

func cReturnType(_ returns: ReturnType, _ element: Element) -> String {
    switch returns {
    case .vector: return element.cVector
    case .mask: return element.cMask
    case .lane: return element.cType
    case .count: return "size_t"
    case .index: return "intptr_t"
    case .boolean: return "bool"
    case .void: return "void"
    }
}

func swiftReturnType(_ returns: ReturnType, scope: String = "") -> String {
    switch returns {
    case .vector: return "\(scope)Vector"
    case .mask: return "\(scope)Mask"
    case .lane: return "\(scope)Lane"
    case .count, .index: return "Int"
    case .boolean: return "Bool"
    case .void: return "Void"
    }
}

func importedReturnType(_ returns: ReturnType, _ element: Element) -> String {
    switch returns {
    case .vector: return "HighwayReference.\(element.vector)"
    case .mask: return "HighwayReference.\(element.mask)"
    case .lane: return element.swiftType
    case .count, .index: return "Int"
    case .boolean: return "Bool"
    case .void: return "Void"
    }
}

let generationNotice = """
    // Generated by utils/GenerateHighwayOps.swift. Do not edit.
    """

func unavailableSendableConformance(of type: String) -> String {
    """
    @available(*, unavailable)
    extension \(type): Sendable {}
    """
}

func portConversions(of element: Element) -> String {
    let signedTag = "const hn::RebindToSigned<\(element.tag)> di;"
    var output = ""
    output += "HWY_INLINE \(element.vector) \(referenceFunctionName("fromPort", element))"
    output += "(\(element.cVector) v) { return hn::LoadU(\(element.tag)(), "
    output += "reinterpret_cast<const \(element.cType)*>(&v)); }\n"
    output += "HWY_INLINE \(element.cVector) \(referenceFunctionName("toPort", element))"
    output += "(\(element.vector) v) { \(element.cVector) port; "
    output += "hn::StoreU(v, \(element.tag)(), reinterpret_cast<\(element.cType)*>(&port)); "
    output += "return port; }\n"
    output += "HWY_INLINE \(element.mask) \(referenceFunctionName("maskFromPort", element))"
    output += "(\(element.cMask) m) { \(signedTag) return hn::MaskFromVec(hn::BitCast("
    output += "\(element.tag)(), hn::LoadU(di, "
    output += "reinterpret_cast<const \(element.cMaskLane)*>(&m)))); }\n"
    output += "HWY_INLINE \(element.cMask) \(referenceFunctionName("maskToPort", element))"
    output += "(\(element.mask) m) { \(signedTag) \(element.cMask) port; "
    output += "hn::StoreU(hn::BitCast(di, hn::VecFromMask(\(element.tag)(), m)), di, "
    output += "reinterpret_cast<\(element.cMaskLane)*>(&port)); return port; }\n"
    return output
}

func generateReferenceHeader() -> String {
    var output = """
        \(generationNotice)

        #ifndef SWIFT_HIGHWAY_REFERENCE_H
        #define SWIFT_HIGHWAY_REFERENCE_H

        #include <stddef.h>
        #include <stdint.h>
        #include "CHighwayOps.h"

        // HWY_DISABLED_TARGETS is set by the build, see HighwayReference/Package.swift.
        #include "hwy/highway.h"

        #if CHIGHWAY_OPS_NEON
        #define CHIGHWAY_REFERENCE_TARGETS HWY_ALL_NEON
        #elif CHIGHWAY_OPS_X86 == 3
        #define CHIGHWAY_REFERENCE_TARGETS HWY_SSE4
        #elif CHIGHWAY_OPS_X86 == 2
        #define CHIGHWAY_REFERENCE_TARGETS HWY_SSSE3
        #elif CHIGHWAY_OPS_X86 == 1
        #define CHIGHWAY_REFERENCE_TARGETS HWY_SSE2
        #else
        #define CHIGHWAY_REFERENCE_TARGETS HWY_EMU128
        #endif
        #if !(HWY_TARGET & CHIGHWAY_REFERENCE_TARGETS)
        #error "highway's static target is not the port's"
        #endif

        namespace HighwayReference {
        namespace hn = hwy::HWY_NAMESPACE;

        /// Whether the static target only emulates vectors, in which case a caller is better off
        /// with its own scalar code.
        HWY_INLINE bool isEmulated() {
          return HWY_TARGET == HWY_SCALAR || HWY_TARGET == HWY_EMU128;
        }

        /// The name of the target the ops below were compiled for.
        HWY_INLINE const char* targetName() { return hwy::TargetName(HWY_TARGET); }


        """

    for element in elements {
        output += "using \(element.tag) = hn::ScalableTag<\(element.cType)>;\n"
        output += "using \(element.vector) = hn::VFromD<\(element.tag)>;\n"
        output += "using \(element.mask) = hn::MFromD<\(element.tag)>;\n"
        output += "HWY_INLINE size_t \(referenceFunctionName("laneCount", element))()"
        output += " { return hn::Lanes(\(element.tag)()); }\n"
        output += portConversions(of: element)

        for op in ops where op.applies.matches(element) {
            let parameterBindings = bindings(of: op, for: element)
            let declarations =
                parameterBindings
                .filter { !$0.declaration.isEmpty }
                .map(\.declaration)
                .joined(separator: ", ")
            let arguments = parameterBindings.map(\.argument).joined(separator: ", ")
            let returnKeyword = op.returns == .void ? "" : "return "
            output += "HWY_INLINE \(referenceReturnType(op.returns, element)) "
            output += "\(referenceFunctionName(op.swiftName, element))(\(declarations))"
            output += " { \(returnKeyword)hn::\(op.highwayName)(\(arguments)); }\n"
        }

        for op in wideningOps {
            for narrow in wideningSources(of: element) {
                let countDeclaration = op.takesCount ? ", size_t count" : ""
                let countArgument = op.takesCount ? ", count" : ""
                let narrowTag = "hn::Rebind<\(narrow.cType), \(element.tag)>()"
                output += "HWY_INLINE \(element.vector) "
                output += "\(wideningFunctionName(op, from: narrow, to: element))"
                output += "(const \(narrow.cType)* from\(countDeclaration))"
                output += " { return hn::PromoteTo(\(element.tag)(), "
                output += "hn::\(op.highwayName)(\(narrowTag), from\(countArgument))); }\n"
            }
        }

        let blockLanes = repeatingBlockLanes(of: element)
        output += "HWY_INLINE \(element.vector) "
        output += "\(referenceFunctionName(repeatingBlockName, element))("
        output += blockLanes.map { "\(element.cType) \($0)" }.joined(separator: ", ")
        output += ") { return hn::Dup128VecFromValues(\(element.tag)(), "
        output += "\(blockLanes.joined(separator: ", "))); }\n"
        output += "\n"
    }

    output += """
        }  // namespace HighwayReference

        #endif

        """
    return output
}

func wideningBody(takesCount: Bool, from narrow: Element, to wide: Element) -> String {
    let lanes = wide.laneCount
    let bytes = lanes * narrow.bits / 8
    let declaration = takesCount ? "narrow_vector v = {0};" : "narrow_vector v;"
    let size =
        takesCount
        ? "\(clampedCount(to: lanes)) * sizeof(\(narrow.cType))"
        : "sizeof v"
    return """
        typedef \(narrow.cType) narrow_vector __attribute__((vector_size(\(bytes))));
        \(declaration)
        __builtin_memcpy(&v, from, \(size));
        return __builtin_convertvector(v, \(wide.cVector));
        """
}

func repeatingBlockBody(of element: Element) -> String {
    "return \(compoundLiteral(element.cVector, repeatingBlockLanes(of: element)));"
}

typealias TargetBranch = (condition: String, body: String)

let neonCondition = "CHIGHWAY_OPS_NEON"

func mergingIdenticalBodies(_ branches: [TargetBranch]) -> [TargetBranch] {
    var merged: [TargetBranch] = []
    for branch in branches {
        if let previous = merged.last, previous.body == branch.body,
            previous.condition != neonCondition
        {
            merged[merged.count - 1] = branch
        } else {
            merged.append(branch)
        }
    }
    guard let neon = merged.first, neon.condition == neonCondition,
        let index = merged.lastIndex(where: {
            $0.body == neon.body && $0.condition != neonCondition
        })
    else { return merged }
    merged[index].condition = "\(neonCondition) || \(merged[index].condition)"
    return Array(merged.dropFirst())
}

func cBody<Input>(
    _ targets: TargetBodies<Input>,
    for input: Input,
    portable: String
) -> String {
    let conditions = [
        (neonCondition, targets.neon),
        ("CHIGHWAY_OPS_X86 >= 3", targets.sse4),
        ("CHIGHWAY_OPS_X86 >= 2", targets.ssse3),
        ("CHIGHWAY_OPS_X86 >= 1", targets.sse2),
    ]
    let branches = mergingIdenticalBodies(
        conditions.compactMap { condition, body in
            body?(input).map { (condition: condition, body: $0) }
        }
    )
    guard !branches.isEmpty else { return portable }
    let chain = branches.enumerated().flatMap { index, branch in
        ["#\(index == 0 ? "if" : "elif") \(branch.condition)", branch.body]
    }
    return (chain + ["#else", portable, "#endif"]).joined(separator: "\n")
}

func cBody(of op: Op, for element: Element) -> String {
    cBody(op.targets, for: element, portable: op.portable(element))
}

func cBody(of op: WideningOp, from narrow: Element, to wide: Element) -> String {
    cBody(
        op.targets,
        for: (narrow, wide),
        portable: wideningBody(takesCount: op.takesCount, from: narrow, to: wide)
    )
}

func rawVectorDeclarations() -> String {
    let groups = [("CHIGHWAY_OPS_NEON", neonVectors), ("CHIGHWAY_OPS_X86", x86Vectors)]
    return groups.map { condition, vectors in
        let typedefs = vectors.map {
            "typedef \($0.lane) \($0.name) __attribute__((\($0.attribute)));"
        }
        return (["#if \(condition)"] + typedefs + ["#endif"]).joined(separator: "\n")
    }
    .joined(separator: "\n\n")
}

func cFunction(returns: String, name: String, parameters: [String], body: String) -> String {
    let signature = parameters.isEmpty ? "void" : parameters.joined(separator: ", ")
    let lines = body.split(separator: "\n", omittingEmptySubsequences: false).map {
        $0.hasPrefix("#") ? String($0) : "  \($0)"
    }
    return """
        CHIGHWAY_OPS_INLINE \(returns) \(name)(\(signature)) {
        \(lines.joined(separator: "\n"))
        }

        """
}

func generateHeader() -> String {
    var output = """
        \(generationNotice)

        #ifndef SWIFT_HIGHWAY_OPS_H
        #define SWIFT_HIGHWAY_OPS_H

        #include <stdbool.h>
        #include <stddef.h>
        #include <stdint.h>

        #ifdef __cplusplus
        extern "C" {
        #endif

        #define CHIGHWAY_OPS_INLINE static inline __attribute__((always_inline))

        #if defined(CHIGHWAY_OPS_PORTABLE)
        #define CHIGHWAY_OPS_NEON 0
        #define CHIGHWAY_OPS_X86 0
        #elif defined(__aarch64__)
        #define CHIGHWAY_OPS_NEON 1
        #define CHIGHWAY_OPS_X86 0
        #elif defined(__SSE4_2__)
        #define CHIGHWAY_OPS_NEON 0
        #define CHIGHWAY_OPS_X86 3
        #elif defined(__SSSE3__)
        #define CHIGHWAY_OPS_NEON 0
        #define CHIGHWAY_OPS_X86 2
        #elif defined(__SSE2__)
        #define CHIGHWAY_OPS_NEON 0
        #define CHIGHWAY_OPS_X86 1
        #else
        #define CHIGHWAY_OPS_NEON 0
        #define CHIGHWAY_OPS_X86 0
        #endif

        \(rawVectorDeclarations())

        /// Whether the target only emulates vectors, in which case a caller is better off
        /// with its own scalar code.
        CHIGHWAY_OPS_INLINE bool chighway_ops_is_emulated(void) {
        #if CHIGHWAY_OPS_NEON || CHIGHWAY_OPS_X86 || defined(__ARM_NEON) || defined(__SSE2__) || \\
            defined(__ALTIVEC__) || defined(__VEC__) || defined(__loongarch_sx) ||               \\
            defined(__wasm_simd128__) || defined(__riscv_v)
          return false;
        #else
          return true;
        #endif
        }

        /// The name of the target the ops below were compiled for.
        CHIGHWAY_OPS_INLINE const char* chighway_ops_target_name(void) {
        #if CHIGHWAY_OPS_NEON
          return "NEON";
        #elif CHIGHWAY_OPS_X86 >= 3
          return "SSE4";
        #elif CHIGHWAY_OPS_X86 >= 2
          return "SSSE3";
        #elif CHIGHWAY_OPS_X86 >= 1
          return "SSE2";
        #else
          return "EMU128";
        #endif
        }


        """

    for element in elements {
        output += """
            typedef \(element.cType) \(element.cVector) __attribute__((vector_size(16)));
            typedef \(element.cMaskLane) \(element.cMask) __attribute__((vector_size(16)));

            """
        output += cFunction(
            returns: "size_t",
            name: cFunctionName("laneCount", element),
            parameters: [],
            body: "return \(element.laneCount);"
        )

        for op in ops where op.applies.matches(element) {
            let parameters =
                bindings(of: op, for: element)
                .filter { !$0.cDeclaration.isEmpty }
                .map(\.cDeclaration)
            output += cFunction(
                returns: cReturnType(op.returns, element),
                name: cFunctionName(op.swiftName, element),
                parameters: parameters,
                body: cBody(of: op, for: element)
            )
        }

        for op in wideningOps {
            for narrow in wideningSources(of: element) {
                let countParameters = op.takesCount ? ["size_t count"] : []
                output += cFunction(
                    returns: element.cVector,
                    name: cWideningFunctionName(op, from: narrow, to: element),
                    parameters: ["const \(narrow.cType)* from"] + countParameters,
                    body: cBody(of: op, from: narrow, to: element)
                )
            }
        }

        output += cFunction(
            returns: element.cVector,
            name: cFunctionName(repeatingBlockName, element),
            parameters: repeatingBlockLanes(of: element).map { "\(element.cType) \($0)" },
            body: repeatingBlockBody(of: element)
        )
        output += "\n"
    }

    output += """
        #ifdef __cplusplus
        }
        #endif

        #endif

        """
    return output
}

func swiftArgument(_ binding: Binding, _ parameter: Parameter) -> String {
    switch parameter {
    case .tag: return ""
    case .mask: return "\(binding.swiftName)._storage"
    case .shiftAmount: return "Int32(truncatingIfNeeded: \(binding.swiftName))"
    case .outVector: return "&\(binding.swiftName)"
    default: return binding.swiftName
    }
}

func importedType(of parameter: Parameter, for element: Element) -> String {
    switch parameter {
    case .tag: return ""
    case .vector, .indices, .outVector: return "HighwayReference.\(element.vector)"
    case .mask: return "HighwayReference.\(element.mask)"
    case .lane: return element.swiftType
    case .constLanePointer: return "UnsafePointer<\(element.swiftType)>"
    case .lanePointer: return "UnsafeMutablePointer<\(element.swiftType)>"
    case .count, .laneAmount: return "Int"
    case .shiftAmount: return "Int32"
    }
}

func swiftDeclaration(_ binding: Binding, as type: String? = nil) -> String {
    let label = binding.swiftLabel ?? binding.swiftName
    let inoutKeyword = binding.isInOut ? "inout " : ""
    let naming =
        label == binding.swiftName
        ? binding.swiftName
        : "\(label) \(binding.swiftName)"
    return "\(naming): \(inoutKeyword)\(type ?? binding.swiftType)"
}

/// How a Swift call passes `binding`, or `expression` in its place, on to a function that has the
/// same parameter.
func swiftCallArgument(_ binding: Binding, passing expression: String? = nil) -> String {
    let label = binding.swiftLabel ?? binding.swiftName
    let operand = expression ?? binding.swiftName
    let value = binding.isInOut ? "&\(operand)" : operand
    return label == "_" ? value : "\(label): \(value)"
}

func swiftSignature(of op: Op, for element: Element) -> (parameters: String, arguments: String) {
    let parameterBindings = bindings(of: op, for: element)
    var declarations: [String] = []
    var arguments: [String] = []

    for (binding, parameter) in zip(parameterBindings, op.parameters) {
        if case .tag = parameter { continue }
        declarations.append(swiftDeclaration(binding))
        arguments.append(swiftArgument(binding, parameter))
    }

    return (declarations.joined(separator: ", "), arguments.joined(separator: ", "))
}

/// An op that takes a pointer is the only kind whose call is an unsafe construct, so only those
/// acknowledge it, rather than the package turning the diagnostic down for every op.
func isUnsafe(_ op: Op) -> Bool {
    op.parameters.contains { parameter in
        switch parameter {
        case .constLanePointer, .lanePointer: return true
        default: return false
        }
    }
}

func swiftBody(of op: Op, for element: Element, arguments: String) -> String {
    let keyword = isUnsafe(op) ? "unsafe " : ""
    let call = "\(keyword)\(cFunctionName(op.swiftName, element))(\(arguments))"
    switch op.returns {
    case .count, .index: return "Int(\(call))"
    case .mask: return "Mask(\(call))"
    default: return call
    }
}

// `Span` needs newer OSes than the macOS 10.13 and iOS 12.0 SwiftPM 6.3 builds for by default.
let spanAvailability = "@available(SwiftStdlib 5.1, *)"

// A Swift parameter of a span form. The span's label differs between the forms of an op.
enum SpanParameter {
    case span
    case other(declaration: String, argument: String)
}

// A pointer op as its span forms see it, so that an `Op` and a `WideningOp` get the same ones.
// `bridgeCall` calls the bridge with the given pointer, and the given count if it takes one.
struct SpanForms {
    let name: String
    let parameters: [SpanParameter]
    let returns: ReturnType
    let extent: SpanExtent
    let element: String
    let isMutable: Bool
    let bridgeCall: (_ pointer: String, _ count: String) -> String
}

func spanForms(of op: Op, for element: Element) -> SpanForms? {
    guard let extent = op.span else { return nil }
    let parameterBindings = bindings(of: op, for: element)
    let takesCountFromSpan = if case .first = extent { true } else { false }

    var parameters: [SpanParameter] = []
    for (binding, parameter) in zip(parameterBindings, op.parameters) {
        switch parameter {
        case .tag:
            continue
        case .count where takesCountFromSpan:
            continue
        case .constLanePointer, .lanePointer:
            parameters.append(.span)
        default:
            parameters.append(
                .other(declaration: swiftDeclaration(binding), argument: swiftCallArgument(binding))
            )
        }
    }

    return SpanForms(
        name: op.swiftName,
        parameters: parameters,
        returns: op.returns,
        extent: extent,
        element: "Lane",
        isMutable: op.parameters.contains(.lanePointer),
        bridgeCall: { pointer, count in
            var arguments: [String] = []
            for (binding, parameter) in zip(parameterBindings, op.parameters) {
                switch parameter {
                case .tag:
                    continue
                case .count where takesCountFromSpan:
                    arguments.append(count)
                case .constLanePointer, .lanePointer:
                    arguments.append(pointer)
                default:
                    arguments.append(swiftArgument(binding, parameter))
                }
            }
            return swiftBody(of: op, for: element, arguments: arguments.joined(separator: ", "))
        }
    )
}

func spanForms(of op: WideningOp, from narrow: Element, to wide: Element) -> SpanForms {
    let function = cWideningFunctionName(op, from: narrow, to: wide)
    return SpanForms(
        name: op.swiftName,
        parameters: [.span],
        returns: .vector,
        extent: op.span,
        element: narrow.swiftType,
        isMutable: false,
        bridgeCall: { pointer, count in
            let countArgument = op.takesCount ? ", \(count)" : ""
            return "unsafe \(function)(\(pointer)\(countArgument))"
        }
    )
}

func spanLabel(_ forms: SpanForms, checked: Bool) -> String {
    let preposition = forms.isMutable ? "to" : "from"
    return checked ? preposition : "\(preposition)Unchecked"
}

func spanSignature(_ forms: SpanForms, label: String) -> (parameters: String, arguments: String) {
    let spanType =
        forms.isMutable ? "inout MutableSpan<\(forms.element)>" : "Span<\(forms.element)>"
    let spanArgument = forms.isMutable ? "&span" : "span"
    var declarations: [String] = []
    var arguments: [String] = []
    for parameter in forms.parameters {
        switch parameter {
        case .span:
            declarations.append("\(label) span: \(spanType)")
            arguments.append("\(label): \(spanArgument)")
        case .other(let declaration, let argument):
            declarations.append(declaration)
            arguments.append(argument)
        }
    }
    return (declarations.joined(separator: ", "), arguments.joined(separator: ", "))
}

/// What a span form checks before it touches `count` vectors' worth of lanes, each as a Swift
/// condition and the message for when it fails.
func spanChecks(vectors count: Int, aligned: Bool) -> [(condition: String, message: String)] {
    var checks = [
        count > 1
            ? (
                "span.count >= \(count) * laneCount",
                "Span has fewer elements than \(count) vectors have lanes"
            )
            : ("span.count >= laneCount", "Span has fewer elements than a vector has lanes")
    ]
    if aligned {
        checks.append(
            (
                "span.withUnsafeBufferPointer { UInt(bitPattern: $0.baseAddress) "
                    + "% UInt(laneCount * MemoryLayout<Lane>.stride) == 0 }",
                "Span does not start at an address aligned to the vector size"
            )
        )
    }
    return checks
}

/// The members that take a span where `forms`' op takes a pointer. A `first` op never touches
/// more than the span has, so it has one form. The others have a checked form that traps when
/// the span is too short or misaligned, and an `@unsafe` unchecked one that only asserts it, like
/// `Span`'s `subscript(_:)` and `subscript(unchecked:)`.
func spanMembers(_ forms: SpanForms) -> String {
    let returnClause = forms.returns == .void ? "" : " -> \(swiftReturnType(forms.returns))"
    let returnKeyword = forms.returns == .void ? "" : "return "
    let accessor = forms.isMutable ? "withUnsafeMutableBufferPointer" : "withUnsafeBufferPointer"
    let checked = spanSignature(forms, label: spanLabel(forms, checked: true))

    guard case .vectors(let count, let aligned) = forms.extent else {
        return """
                \(spanAvailability)
                @export(implementation) @inline(always)
                public static func \(forms.name)(\(checked.parameters))\(returnClause) {
                    span.\(accessor) { \(forms.bridgeCall("$0.baseAddress", "$0.count")) }
                }


            """
    }

    let unchecked = spanSignature(forms, label: spanLabel(forms, checked: false))
    let checks = spanChecks(vectors: count, aligned: aligned)
    let preconditions = checks.map { "precondition(\($0.condition), \"\($0.message)\")" }
    let assertions = checks.map { "assert(\($0.condition), \"\($0.message)\")" }
    return """
            \(spanAvailability)
            @export(implementation) @inline(always)
            public static func \(forms.name)(\(checked.parameters))\(returnClause) {
                \(preconditions.joined(separator: "\n        "))
                \(returnKeyword)unsafe \(forms.name)(\(unchecked.arguments))
            }

            \(spanAvailability)
            @unsafe @export(implementation) @inline(always)
            public static func \(forms.name)(\(unchecked.parameters))\(returnClause) {
                \(assertions.joined(separator: "\n        "))
                \(returnKeyword)span.\(accessor) {
                    \(forms.bridgeCall("$0.baseAddress.unsafelyUnwrapped", "$0.count"))
                }
            }


        """
}

func spanRequirements(_ forms: SpanForms, indent: String) -> String {
    let returnClause = forms.returns == .void ? "" : " -> \(swiftReturnType(forms.returns))"
    let checked = spanSignature(forms, label: spanLabel(forms, checked: true))
    var output = "\(indent)\(spanAvailability)\n"
    output += "\(indent)static func \(forms.name)(\(checked.parameters))\(returnClause)\n"
    guard case .vectors = forms.extent else { return output }
    let unchecked = spanSignature(forms, label: spanLabel(forms, checked: false))
    output += "\(indent)\(spanAvailability)\n"
    output += "\(indent)@unsafe static func \(forms.name)(\(unchecked.parameters))\(returnClause)\n"
    return output
}

/// The name of the form of a store op that appends to an `OutputSpan`, after `UniqueArray`'s
/// `append`s. A `first` op appends as many lanes as it is told to, so it is
/// `append(_:addingCount:to:)`.
func outputSpanName(_ forms: SpanForms) -> String {
    if case .first = forms.extent { return "append" }
    return "append\(forms.name.dropFirst("store".count))"
}

func outputSpanSignature(
    _ forms: SpanForms,
    checked: Bool
) -> (parameters: String, arguments: String) {
    let label = checked ? "to" : "toUnchecked"
    let takesCount = if case .first = forms.extent { true } else { false }
    var declarations: [String] = []
    var arguments: [String] = []
    for parameter in forms.parameters {
        switch parameter {
        case .span:
            if takesCount {
                declarations.append("addingCount: Int")
                arguments.append("addingCount: addingCount")
            }
            declarations.append("\(label) output: inout OutputSpan<\(forms.element)>")
            arguments.append("\(label): &output")
        case .other(let declaration, let argument):
            declarations.append(declaration)
            arguments.append(argument)
        }
    }
    return (declarations.joined(separator: ", "), arguments.joined(separator: ", "))
}

/// What an output span form checks before it appends, each as a Swift condition and the message
/// for when it fails. An `aligned` op also needs the lanes it appends to start at an address
/// aligned to the vector size.
func outputSpanChecks(_ extent: SpanExtent) -> [(condition: String, message: String)] {
    guard case .vectors(let count, let aligned) = extent else {
        return [
            ("addingCount >= 0 && addingCount <= laneCount", "Count out of bounds"),
            (
                "addingCount <= output.freeCapacity",
                "OutputSpan has less free capacity than the count"
            ),
        ]
    }
    var checks = [
        count > 1
            ? (
                "output.freeCapacity >= \(count) * laneCount",
                "OutputSpan has less free capacity than \(count) vectors have lanes"
            )
            : (
                "output.freeCapacity >= laneCount",
                "OutputSpan has less free capacity than a vector has lanes"
            )
    ]
    if aligned {
        checks.append(
            (
                "output.span.withUnsafeBufferPointer { (UInt(bitPattern: $0.baseAddress) "
                    + "&+ UInt($0.count &* MemoryLayout<Lane>.stride)) "
                    + "% UInt(laneCount * MemoryLayout<Lane>.stride) == 0 }",
                "OutputSpan does not continue at an address aligned to the vector size"
            )
        )
    }
    return checks
}

/// The members that append to an `OutputSpan` where `forms`' store op takes a pointer. Like the
/// span forms, a checked form traps when the output span has too little free capacity, the count
/// is out of bounds, or the lanes would be misaligned, and an `@unsafe` unchecked one only
/// asserts it. An empty `OutputSpan` can have no buffer at all, which only a `first` op can be
/// given, to append no lanes to.
func outputSpanMembers(_ forms: SpanForms) -> String {
    let name = outputSpanName(forms)
    let checked = outputSpanSignature(forms, checked: true)
    let unchecked = outputSpanSignature(forms, checked: false)
    let checks = outputSpanChecks(forms.extent)
    let preconditions = checks.map { "precondition(\($0.condition), \"\($0.message)\")" }
    let assertions = checks.map { "assert(\($0.condition), \"\($0.message)\")" }
    let (pointer, appendedCount) =
        switch forms.extent {
        case .first:
            ("buffer.baseAddress?.advanced(by: initializedCount)", "addingCount")
        case .vectors(let count, _):
            (
                "buffer.baseAddress.unsafelyUnwrapped + initializedCount",
                count > 1 ? "\(count) * laneCount" : "laneCount"
            )
        }
    return """
            \(spanAvailability)
            @export(implementation) @inline(always)
            public static func \(name)(\(checked.parameters)) {
                \(preconditions.joined(separator: "\n        "))
                unsafe \(name)(\(unchecked.arguments))
            }

            \(spanAvailability)
            @unsafe @export(implementation) @inline(always)
            public static func \(name)(\(unchecked.parameters)) {
                \(assertions.joined(separator: "\n        "))
                unsafe output.withUnsafeMutableBufferPointer { buffer, initializedCount in
                    \(forms.bridgeCall(pointer, "addingCount"))
                    initializedCount &+= \(appendedCount)
                }
            }


        """
}

func outputSpanRequirements(_ forms: SpanForms, indent: String) -> String {
    let name = outputSpanName(forms)
    let checked = outputSpanSignature(forms, checked: true)
    let unchecked = outputSpanSignature(forms, checked: false)
    var output = "\(indent)\(spanAvailability)\n"
    output += "\(indent)static func \(name)(\(checked.parameters))\n"
    output += "\(indent)\(spanAvailability)\n"
    output += "\(indent)@unsafe static func \(name)(\(unchecked.parameters))\n"
    return output
}

let integerElements = elements.filter { $0.category != .float }
let floatElements = elements.filter { $0.category == .float }

func opsApplyingToAll(_ candidates: [Element]) -> [Op] {
    ops.filter { op in candidates.allSatisfy(op.applies.matches) }
}

let universalOps = opsApplyingToAll(elements)
let integerOnlyOps = opsApplyingToAll(integerElements)
    .filter { op in !universalOps.contains { $0.swiftName == op.swiftName } }
let floatOnlyOps = opsApplyingToAll(floatElements)
    .filter { op in !universalOps.contains { $0.swiftName == op.swiftName } }

func protocolRequirements(_ requirementOps: [Op], indent: String) -> String {
    var output = ""
    for op in requirementOps {
        let signature = swiftSignature(of: op, for: elements[0])
        let returnClause = op.returns == .void ? "" : " -> \(swiftReturnType(op.returns))"
        output += "\(indent)static func \(op.swiftName)(\(signature.parameters))\(returnClause)\n"
        if let forms = spanForms(of: op, for: elements[0]) {
            output += spanRequirements(forms, indent: indent)
            if forms.isMutable {
                output += outputSpanRequirements(forms, indent: indent)
            }
        }
    }
    return output
}

func generateProtocols() -> String {
    let declarations = """
        /// An element type that Highway's vectors can hold, and the ops every such type has.
        ///
        /// Conformances are the `Highway…` enumerations, so that a kernel can be written once and
        /// used for any element type: `func sum<E: HighwayElement>(_ type: E.Type, …)`.
        public protocol HighwayElement {
            associatedtype Lane
            associatedtype Vector
            associatedtype Mask

            /// How many lanes of `Lane` a `Vector` holds on the target this was compiled for.
            static var laneCount: Int { get }

        \(protocolRequirements(universalOps, indent: "    "))}

        /// The ops that only the integer element types have.
        public protocol HighwayIntegerElement: HighwayElement {
        \(protocolRequirements(integerOnlyOps, indent: "    "))}

        /// The ops that only the floating point element types have.
        public protocol HighwayFloatElement: HighwayElement {
        \(protocolRequirements(floatOnlyOps, indent: "    "))}
        """

    return "\(generationNotice)\n\n\(declarations)\n"
}

func generateElement(_ element: Element) -> String {
    var conformances = ["HighwayElement"]
    if element.category == .float {
        conformances.append("HighwayFloatElement")
    } else {
        conformances.append("HighwayIntegerElement")
    }
    conformances.append("SendableMetatype")

    var output = """
        \(generationNotice)

        public import CHighwayOps

        /// Highway's vectors of `\(element.swiftType)`, and the ops over them.
        public enum \(element.namespace): \(conformances.joined(separator: ", ")) {
            public typealias Lane = \(element.swiftType)
            public typealias Vector = \(element.swiftVector)
            public typealias Mask = \(element.swiftMask)

            @export(implementation) @inline(always)
            public static var laneCount: Int { Int(\(cFunctionName("laneCount", element))()) }


        """

    for op in ops where op.applies.matches(element) {
        let signature = swiftSignature(of: op, for: element)
        let returnClause = op.returns == .void ? "" : " -> \(swiftReturnType(op.returns))"
        let body = swiftBody(of: op, for: element, arguments: signature.arguments)
        output += "    @export(implementation) @inline(always)\n"
        output +=
            "    public static func \(op.swiftName)(\(signature.parameters))\(returnClause) {\n"
        output += "        \(body)\n"
        output += "    }\n\n"
        if let forms = spanForms(of: op, for: element) {
            output += spanMembers(forms)
            if forms.isMutable {
                output += outputSpanMembers(forms)
            }
        }
    }

    for op in wideningOps {
        for narrow in wideningSources(of: element) {
            let countParameter = op.takesCount ? ", count: Int" : ""
            let countArgument = op.takesCount ? ", count" : ""
            let function = cWideningFunctionName(op, from: narrow, to: element)
            output += "    @export(implementation) @inline(always)\n"
            output += "    public static func \(op.swiftName)("
            output += "from: UnsafePointer<\(narrow.swiftType)>\(countParameter)"
            output += ") -> Vector {\n"
            output += "        unsafe \(function)(from\(countArgument))\n"
            output += "    }\n\n"
            output += spanMembers(spanForms(of: op, from: narrow, to: element))
        }
    }

    let blockLanes = repeatingBlockLanes(of: element)
    output += "    @export(implementation) @inline(always)\n"
    output += "    public static func \(repeatingBlockName)("
    output += blockLanes.map { "_ \($0): Lane" }.joined(separator: ", ")
    output += ") -> Vector {\n"
    output += "        \(cFunctionName(repeatingBlockName, element))("
    output += "\(blockLanes.joined(separator: ", ")))\n"
    output += "    }\n\n"

    output += "}\n\n\(unavailableSendableConformance(of: element.namespace))\n"

    return output
}

func fnv1a(_ text: String) -> UInt64 {
    text.utf8.reduce(0xCBF2_9CE4_8422_2325) { ($0 ^ UInt64($1)) &* 0x100_0000_01B3 }
}

func referenceTestSeed(_ element: Element, _ test: String, _ input: String) -> String {
    String(format: "0x%016llX", fnv1a("\(element.suffix)/\(test)/\(input)"))
}

struct ReferenceInput {
    let parameter: Parameter
    let name: String
    let values: String

    var description: String {
        switch parameter {
        case .lane: return "hex(\(name))"
        case .count, .shiftAmount, .laneAmount: return name
        default: return "describe(\(name))"
        }
    }
}

func hasOutOfContractInputs(_ op: Op) -> Bool {
    op.parameters.contains { parameter in
        switch parameter {
        case .shiftAmount, .laneAmount, .indices: return true
        default: return false
        }
    }
}

func isAligned(_ op: Op) -> Bool {
    guard case .vectors(_, let aligned)? = op.span else { return false }
    return aligned
}

func pointerLanes(of op: Op, for element: Element) -> Int {
    switch op.span {
    case .vectors(let count, _)?: return count * element.laneCount
    case .first?: return element.laneCount
    case nil: fatalError("\(op.swiftName) takes a pointer but has no span extent")
    }
}

func pointerExpression(_ closureParameter: String, aligned: Bool) -> String {
    aligned ? closureParameter : "\(closureParameter).baseAddress!"
}

/// The lanes of `buffer` that a pointer op with `extent` may touch, which a guarded test puts right
/// before an inaccessible page.
func guardedLanes(of buffer: String, extent: SpanExtent?) -> String {
    guard case .first? = extent else { return buffer }
    return "Array(\(buffer).prefix(count))"
}

func referenceInputs(
    of op: Op,
    for element: Element,
    test: String,
    inContract: Bool
) -> [ReferenceInput] {
    var inputs: [ReferenceInput] = []
    for (binding, parameter) in zip(bindings(of: op, for: element), op.parameters) {
        let seed = "seed: \(referenceTestSeed(element, test, String(inputs.count)))"
        let values: String
        switch parameter {
        case .tag, .lanePointer, .outVector:
            continue
        case .vector:
            values = "Inputs.vectors(H.Vector.self, \(seed))"
        case .indices:
            values = "Inputs.tableIndices(H.Vector.self, \(seed), inContract: \(inContract))"
        case .mask:
            values = "Inputs.masks(H.Mask.self, \(seed))"
        case .lane:
            values = "Inputs.lanes(H.Lane.self, \(seed))"
        case .count where op.span != nil:
            values = "Inputs.bufferCounts(lanes: H.laneCount)"
        case .count:
            values = "Inputs.maskCounts(lanes: H.laneCount, lane: \(element.swiftMaskLane).self)"
        case .shiftAmount:
            values = "Inputs.shiftAmounts(bits: \(element.bits), inContract: \(inContract))"
        case .laneAmount:
            values = "Inputs.laneAmounts(lanes: H.laneCount, inContract: \(inContract))"
        case .constLanePointer:
            let lanes = pointerLanes(of: op, for: element)
            values = "Inputs.buffers(H.Lane.self, count: \(lanes), \(seed))"
        }
        inputs.append(ReferenceInput(parameter: parameter, name: binding.swiftName, values: values))
    }
    return inputs
}

let referenceCombinators = [2: "everyPair", 3: "mixedTriples", 4: "mixedQuadruples"]

func referenceLoop(over inputs: [ReferenceInput], for element: Element, test: String) -> String? {
    guard let first = inputs.first else { return nil }
    guard inputs.count > 1 else { return "for \(first.name) in \(first.name)Inputs" }
    guard let combinator = referenceCombinators[inputs.count] else {
        fatalError("\(test) has \(inputs.count) inputs, which nothing combines")
    }
    var arguments = inputs.map { "\($0.name)Inputs" }
    if inputs.count > 2 {
        arguments.append("seed: \(referenceTestSeed(element, test, "combinations"))")
    }
    let names = inputs.map(\.name).joined(separator: ", ")
    return "for (\(names)) in \(combinator)(\(arguments.joined(separator: ", ")))"
}

func referenceDescription(of inputs: [ReferenceInput], suffix: String = "") -> String {
    let fields = inputs.map { "\($0.name): \\(\($0.description))" }
    return "\"\(fields.joined(separator: ", "))\(suffix)\""
}

func portCall(_ name: String, _ arguments: [String], on type: String = "H") -> String {
    "\(type).\(name)(\(arguments.joined(separator: ", ")))"
}

func referenceCall(_ name: String, _ arguments: [String]) -> String {
    "HighwayReference.\(name)(\(arguments.joined(separator: ", ")))"
}

func referenceResult(_ call: String, returning returns: ReturnType) -> String {
    switch returns {
    case .vector, .mask: return "port(\(call))"
    default: return call
    }
}

func referenceCalls(
    of op: Op,
    for element: Element,
    pointer: String
) -> (port: String, reference: String) {
    var portArguments: [String] = []
    var referenceArguments: [String] = []
    var outVectorIndex = 0

    for (binding, parameter) in zip(bindings(of: op, for: element), op.parameters) {
        switch parameter {
        case .tag:
            continue
        case .vector, .indices, .mask:
            portArguments.append(swiftCallArgument(binding))
            referenceArguments.append("reference(\(binding.swiftName))")
        case .lane, .count, .shiftAmount, .laneAmount:
            portArguments.append(swiftCallArgument(binding))
            referenceArguments.append(swiftArgument(binding, parameter))
        case .constLanePointer, .lanePointer:
            portArguments.append(swiftCallArgument(binding, passing: pointer))
            referenceArguments.append(pointer)
        case .outVector:
            portArguments.append(swiftCallArgument(binding, passing: "p\(outVectorIndex)"))
            referenceArguments.append("&r\(outVectorIndex)")
            outVectorIndex += 1
        }
    }

    let keyword = isUnsafe(op) ? "unsafe " : ""
    let call = referenceCall(referenceFunctionName(op.swiftName, element), referenceArguments)
    let reference = referenceResult(call, returning: op.returns)
    return ("\(keyword)\(portCall(op.swiftName, portArguments))", "\(keyword)\(reference)")
}

let emulatedShiftAttribute = """
    @Test(
        .disabled(
            if: Highway.targetName == "EMU128",
            "EMU128 has no defined result for these shift counts"
        )
    )
    """

func referenceTestFunction(
    _ test: String,
    label: String,
    for element: Element,
    inputs: [ReferenceInput],
    declarations: [String] = [],
    disabledOnEmulation: Bool = false,
    statements: String
) -> String {
    let header =
        disabledOnEmulation
        ? "\(emulatedShiftAttribute)\nfunc \(test)() {"
        : "@Test func \(test)() {"
    var lines = ["let mismatches = Mismatches(\"\(label)\")"]
    lines += inputs.map { "let \($0.name)Inputs = \($0.values)" }
    lines += declarations
    if let loop = referenceLoop(over: inputs, for: element, test: test) {
        lines.append("\(loop) {\n\(statements)\n}")
    } else {
        lines.append(statements)
    }
    lines.append("mismatches.record()")
    return """
        \(header)
        \(lines.joined(separator: "\n"))
        }
        """
}

func referenceLoadStatements(
    of source: String,
    aligned: Bool,
    guardedLanes: String?,
    port: String,
    reference: String,
    description: String
) -> String {
    let results = "(\(port), \(reference))"
    let scope =
        if let guardedLanes {
            "unsafe withGuardedLanes(\(guardedLanes)) { source in \(results) }.result"
        } else if aligned {
            "unsafe withAlignedLanes(\(source)) { source in \(results) }.result"
        } else {
            "\(source).withUnsafeBufferPointer { source in \(results) }"
        }
    return """
        let (portResult, referenceResult) = \(scope)
        mismatches.check(portResult, referenceResult, \(description))
        """
}

func referenceOutVectorStatements(
    of source: String,
    count: Int,
    for element: Element,
    guardedLanes: String?,
    port: String,
    reference: String,
    inputs: [ReferenceInput]
) -> String {
    let zero = referenceCall(referenceFunctionName("zero", element), [])
    var statements = (0..<count).map { "var p\($0) = \(portCall("zero", []))" }
    statements += (0..<count).map { "var r\($0) = \(zero)" }
    let calls = "{ source in\n\(port)\n\(reference)\n}"
    if let guardedLanes {
        statements.append("_ = unsafe withGuardedLanes(\(guardedLanes)) \(calls)")
    } else {
        statements.append("\(source).withUnsafeBufferPointer \(calls)")
    }
    for index in 0..<count {
        let description = referenceDescription(of: inputs, suffix: ", v\(index)")
        statements.append("mismatches.check(p\(index), port(r\(index)), \(description))")
    }
    return statements.joined(separator: "\n")
}

func referenceStoreStatements(
    aligned: Bool,
    guardedLanes: String?,
    port: String,
    reference: String,
    description: String
) -> String {
    let stores = [("portLanes", port), ("referenceLanes", reference)].map { lanes, call in
        let closure = "{ destination in \(call) }"
        if let guardedLanes {
            return "let \(lanes) = unsafe withGuardedLanes(\(guardedLanes)) \(closure).lanes"
        }
        return aligned
            ? "let \(lanes) = unsafe withAlignedLanes(sentinel) \(closure).lanes"
            : "var \(lanes) = sentinel\n\(lanes).withUnsafeMutableBufferPointer \(closure)"
    }
    let comparison = "mismatches.check(portLanes, referenceLanes, \(description))"
    return (stores + [comparison]).joined(separator: "\n")
}

func referenceTest(
    of op: Op,
    for element: Element,
    inContract: Bool,
    guarded: Bool = false
) -> String {
    let (test, label) =
        if guarded {
            ("\(op.swiftName)BeforeGuardPage", "\(op.swiftName) before a guard page")
        } else if inContract {
            (op.swiftName, op.swiftName)
        } else {
            ("\(op.swiftName)OutOfContract", "\(op.swiftName) out of contract")
        }
    let inputs = referenceInputs(of: op, for: element, test: test, inContract: inContract)
    let description = referenceDescription(of: inputs)
    let aligned = isAligned(op)
    let isStore = op.parameters.contains(.lanePointer)
    let pointer = pointerExpression(isStore ? "destination" : "source", aligned: aligned || guarded)
    let calls = referenceCalls(of: op, for: element, pointer: pointer)
    var declarations: [String] = []
    let statements: String

    if let source = inputs.first(where: { $0.parameter == .constLanePointer })?.name {
        let outVectors = op.parameters.filter { $0 == .outVector }.count
        statements =
            outVectors == 0
            ? referenceLoadStatements(
                of: source,
                aligned: aligned,
                guardedLanes: guarded ? guardedLanes(of: source, extent: op.span) : nil,
                port: calls.port,
                reference: calls.reference,
                description: description
            )
            : referenceOutVectorStatements(
                of: source,
                count: outVectors,
                for: element,
                guardedLanes: guarded ? guardedLanes(of: source, extent: op.span) : nil,
                port: calls.port,
                reference: calls.reference,
                inputs: inputs
            )
    } else if isStore {
        let lanes = pointerLanes(of: op, for: element)
        let count = guarded ? "\(lanes)" : "\(lanes) + 4"
        declarations.append("let sentinel = Inputs.sentinel(H.Lane.self, count: \(count))")
        statements = referenceStoreStatements(
            aligned: aligned,
            guardedLanes: guarded ? guardedLanes(of: "sentinel", extent: op.span) : nil,
            port: calls.port,
            reference: calls.reference,
            description: description
        )
    } else {
        statements = "mismatches.check(\(calls.port), \(calls.reference), \(description))"
    }

    return referenceTestFunction(
        test,
        label: label,
        for: element,
        inputs: inputs,
        declarations: declarations,
        disabledOnEmulation: !inContract && op.parameters.contains(.shiftAmount),
        statements: statements
    )
}

func wideningReferenceTest(
    _ op: WideningOp,
    from narrow: Element,
    to wide: Element,
    guarded: Bool = false
) -> String {
    let name = "\(op.swiftName)From\(narrow.swiftType)"
    let test = guarded ? "\(name)BeforeGuardPage" : name
    let seed = "seed: \(referenceTestSeed(wide, test, "0"))"
    var inputs = [
        ReferenceInput(
            parameter: .constLanePointer,
            name: "from",
            values: "Inputs.buffers(\(narrow.swiftType).self, count: H.laneCount, \(seed))"
        )
    ]
    let pointer = pointerExpression("source", aligned: guarded)
    var portArguments = ["from: \(pointer)"]
    var referenceArguments = [pointer]
    if op.takesCount {
        inputs.append(
            ReferenceInput(
                parameter: .count,
                name: "count",
                values: "Inputs.bufferCounts(lanes: H.laneCount)"
            )
        )
        portArguments.append("count: count")
        referenceArguments.append("count")
    }

    let function = wideningFunctionName(op, from: narrow, to: wide)
    let reference = referenceResult(referenceCall(function, referenceArguments), returning: .vector)
    let suffix = guarded ? " before a guard page" : ""
    return referenceTestFunction(
        test,
        label: "\(op.swiftName) from \(narrow.swiftType)\(suffix)",
        for: wide,
        inputs: inputs,
        statements: referenceLoadStatements(
            of: "from",
            aligned: false,
            guardedLanes: guarded ? guardedLanes(of: "from", extent: op.span) : nil,
            port: "unsafe \(portCall(op.swiftName, portArguments))",
            reference: "unsafe \(reference)",
            description: referenceDescription(of: inputs)
        )
    )
}

func repeatingBlockReferenceTest(for element: Element) -> String {
    let seed = "seed: \(referenceTestSeed(element, repeatingBlockName, "0"))"
    let vectors = ReferenceInput(
        parameter: .vector,
        name: "vector",
        values: "Inputs.vectors(H.Vector.self, \(seed))"
    )
    let lanes = repeatingBlockLanes(of: element).indices.map { "vector[\($0)]" }
    let function = referenceFunctionName(repeatingBlockName, element)
    let port = portCall(repeatingBlockName, lanes)
    let reference = referenceResult(referenceCall(function, lanes), returning: .vector)
    let description = "\"lanes: \\(describe(vector))\""
    return referenceTestFunction(
        repeatingBlockName,
        label: repeatingBlockName,
        for: element,
        inputs: [vectors],
        statements: "mismatches.check(\(port), \(reference), \(description))"
    )
}

func laneCountReferenceTest(for element: Element) -> String {
    let call = referenceCall(referenceFunctionName("laneCount", element), [])
    return referenceTestFunction(
        "laneCount",
        label: "laneCount",
        for: element,
        inputs: [],
        statements: "mismatches.check(H.laneCount, \(call), \"\")"
    )
}

func generateReferenceTests(_ element: Element) -> String {
    var tests = [laneCountReferenceTest(for: element)]
    for op in ops where op.applies.matches(element) {
        tests.append(referenceTest(of: op, for: element, inContract: true))
        if hasOutOfContractInputs(op) {
            tests.append(referenceTest(of: op, for: element, inContract: false))
        }
        if op.span != nil {
            tests.append(referenceTest(of: op, for: element, inContract: true, guarded: true))
        }
    }
    for op in wideningOps {
        for narrow in wideningSources(of: element) {
            tests.append(wideningReferenceTest(op, from: narrow, to: element))
            tests.append(wideningReferenceTest(op, from: narrow, to: element, guarded: true))
        }
    }
    tests.append(repeatingBlockReferenceTest(for: element))

    return """
        \(generationNotice)

        import CHighwayReference
        import Highway
        import Testing

        @Suite("\(element.namespace) against Highway")
        struct \(element.namespace)ReferenceTests {
            typealias H = \(element.namespace)

            func reference(_ vector: H.Vector) -> HighwayReference.\(element.vector) {
                HighwayReference.\(referenceFunctionName("fromPort", element))(vector)
            }

            func port(_ vector: HighwayReference.\(element.vector)) -> H.Vector {
                HighwayReference.\(referenceFunctionName("toPort", element))(vector)
            }

            func reference(_ mask: H.Mask) -> HighwayReference.\(element.mask) {
                HighwayReference.\(referenceFunctionName("maskFromPort", element))(mask._storage)
            }

            func port(_ mask: HighwayReference.\(element.mask)) -> H.Mask {
                H.Mask(HighwayReference.\(referenceFunctionName("maskToPort", element))(mask))
            }

        \(tests.joined(separator: "\n\n"))
        }

        """
}

func codegenFunctionName(_ side: String, _ referenceName: String) -> String {
    "\(side)\(referenceName.prefix(1).uppercased())\(referenceName.dropFirst())"
}

func codegenFunction(
    _ name: String,
    parameters: [String],
    returnClause: String,
    call: String
) -> String {
    """
    @inline(never)
    public func \(name)(\(parameters.joined(separator: ", ")))\(returnClause) {
        \(call)
    }
    """
}

func codegenFunctions(
    _ swiftName: String,
    referenceName: String,
    for element: Element,
    returns: ReturnType,
    isUnsafe: Bool,
    port: (parameters: [String], arguments: [String]),
    reference: (parameters: [String], arguments: [String])
) -> String {
    let keyword = isUnsafe ? "unsafe " : ""
    let hasReturn = returns != .void
    let portReturn = swiftReturnType(returns, scope: "\(element.namespace).")
    let referenceReturn = importedReturnType(returns, element)
    let functions = [
        codegenFunction(
            codegenFunctionName("port", referenceName),
            parameters: port.parameters,
            returnClause: hasReturn ? " -> \(portReturn)" : "",
            call: keyword + portCall(swiftName, port.arguments, on: element.namespace)
        ),
        codegenFunction(
            codegenFunctionName("highway", referenceName),
            parameters: reference.parameters,
            returnClause: hasReturn ? " -> \(referenceReturn)" : "",
            call: keyword + referenceCall(referenceName, reference.arguments)
        ),
    ]
    return functions.joined(separator: "\n\n")
}

func codegenFunctions(of op: Op, for element: Element) -> String {
    var portParameters: [String] = []
    var referenceParameters: [String] = []
    var portArguments: [String] = []
    var referenceArguments: [String] = []

    let parameterBindings = bindings(of: op, for: element, scope: "\(element.namespace).")
    for (binding, parameter) in zip(parameterBindings, op.parameters) {
        if case .tag = parameter { continue }
        let referenceType = importedType(of: parameter, for: element)
        portParameters.append(swiftDeclaration(binding))
        referenceParameters.append(swiftDeclaration(binding, as: referenceType))
        portArguments.append(swiftCallArgument(binding))
        referenceArguments.append(binding.isInOut ? "&\(binding.swiftName)" : binding.swiftName)
    }

    return codegenFunctions(
        op.swiftName,
        referenceName: referenceFunctionName(op.swiftName, element),
        for: element,
        returns: op.returns,
        isUnsafe: isUnsafe(op),
        port: (portParameters, portArguments),
        reference: (referenceParameters, referenceArguments)
    )
}

func codegenFunctions(_ op: WideningOp, from narrow: Element, to wide: Element) -> String {
    var parameters = ["from: UnsafePointer<\(narrow.swiftType)>"]
    var portArguments = ["from: from"]
    var referenceArguments = ["from"]
    if op.takesCount {
        parameters.append("count: Int")
        portArguments.append("count: count")
        referenceArguments.append("count")
    }

    return codegenFunctions(
        op.swiftName,
        referenceName: wideningFunctionName(op, from: narrow, to: wide),
        for: wide,
        returns: .vector,
        isUnsafe: true,
        port: (parameters, portArguments),
        reference: (parameters, referenceArguments)
    )
}

func repeatingBlockCodegenFunctions(for element: Element) -> String {
    let lanes = repeatingBlockLanes(of: element)
    return codegenFunctions(
        repeatingBlockName,
        referenceName: referenceFunctionName(repeatingBlockName, element),
        for: element,
        returns: .vector,
        isUnsafe: false,
        port: (lanes.map { "_ \($0): \(element.namespace).Lane" }, lanes),
        reference: (lanes.map { "_ \($0): \(element.swiftType)" }, lanes)
    )
}

func generateCodegen(_ element: Element) -> String {
    var functions: [String] = []
    for op in ops where op.applies.matches(element) {
        functions.append(codegenFunctions(of: op, for: element))
    }
    for op in wideningOps {
        for narrow in wideningSources(of: element) {
            functions.append(codegenFunctions(op, from: narrow, to: element))
        }
    }
    functions.append(repeatingBlockCodegenFunctions(for: element))

    return """
        \(generationNotice)

        import CHighwayReference
        public import Highway

        \(functions.joined(separator: "\n\n"))

        """
}

func write(_ contents: String, to path: String) throws {
    let url = URL(fileURLWithPath: path)
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try contents.write(to: url, atomically: true, encoding: .utf8)
    FileHandle.standardError.write(Data("** Wrote \(path)\n".utf8))
}

let repositoryRoot = FileManager.default.currentDirectoryPath
let headerPath = "\(repositoryRoot)/Sources/CHighwayOps/include/CHighwayOps.h"
let referenceHeaderPath =
    "\(repositoryRoot)/HighwayReference/CHighwayReference/include/CHighwayReference.h"
let generatedSwiftRoot = "\(repositoryRoot)/Sources/Highway/Generated"
let generatedReferenceTestsRoot =
    "\(repositoryRoot)/HighwayReference/HighwayReferenceTests/Generated"
let generatedCodegenRoot =
    "\(repositoryRoot)/HighwayReference/HighwayReferenceCodegen/Generated"

// The generated Swift is formatted here rather than by hand, so that what this writes and what
// `swift format` wants can never disagree, which would make the two CI checks fight each other.
func format(_ path: String) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [
        "swift", "format", "format", "--in-place", "--parallel", "--recursive", path,
    ]
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        FileHandle.standardError.write(Data("** ERROR: failed to format \(path)\n".utf8))
        exit(1)
    }
}

try? FileManager.default.removeItem(atPath: generatedSwiftRoot)
try? FileManager.default.removeItem(atPath: generatedReferenceTestsRoot)
try? FileManager.default.removeItem(atPath: generatedCodegenRoot)
try write(generateHeader(), to: headerPath)
try write(generateReferenceHeader(), to: referenceHeaderPath)
try write(generateProtocols(), to: "\(generatedSwiftRoot)/HighwayElement.swift")
for element in elements {
    try write(generateElement(element), to: "\(generatedSwiftRoot)/\(element.namespace).swift")
    try write(
        generateReferenceTests(element),
        to: "\(generatedReferenceTestsRoot)/\(element.namespace)ReferenceTests.swift"
    )
    try write(
        generateCodegen(element),
        to: "\(generatedCodegenRoot)/\(element.namespace)Codegen.swift"
    )
}
try format(generatedSwiftRoot)
try format(generatedReferenceTestsRoot)
try format(generatedCodegenRoot)
FileHandle.standardError.write(
    Data("** ✅ Generated \(elements.count) element types.\n".utf8)
)
