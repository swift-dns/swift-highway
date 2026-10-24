// Generates the C header of the ops, the Swift layer over it, the C++ header of the Highway ops
// they are tested against, and the tests that compare the two, from the op list below.
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

struct Op {
    let swiftName: String
    let highwayName: String
    let parameters: [Parameter]
    let returns: ReturnType
    let applies: Applies
    var documentation: String = ""
    let span: SpanExtent?
    let portable: (Element) -> String

    init(
        _ swiftName: String,
        _ highwayName: String,
        _ parameters: [Parameter],
        _ returns: ReturnType,
        _ applies: Applies,
        _ documentation: String = "",
        span: SpanExtent? = nil,
        portable: @escaping (Element) -> String
    ) {
        self.swiftName = swiftName
        self.highwayName = highwayName
        self.parameters = parameters
        self.returns = returns
        self.applies = applies
        self.documentation = documentation
        self.span = span
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
        span: .first
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
        span: .first
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
    Op("multiplying", "Mul", [.vector, .vector], .vector, .all(bits: [16, 32, 64])) { element in
        binaryArithmetic("*", for: element)
    },
    Op("dividing", "Div", [.vector, .vector], .vector, .float) { _ in
        "return a / b;"
    },
    Op("minimum", "Min", [.vector, .vector], .vector, .all) { element in
        elementwiseExtremum("min", comparing: "<", for: element)
    },
    Op("maximum", "Max", [.vector, .vector], .vector, .all) { element in
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
    Op("multiplyAdding", "MulAdd", [.vector, .vector, .vector], .vector, .float) { _ in
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

    Op("shiftedLeft", "ShiftLeftSame", [.vector, .shiftAmount], .vector, .integer) { element in
        let zero = compoundLiteral(element.cVector, ["0"])
        let shifted = fromUnsignedBits("\(unsignedBits("a", of: element)) << bits", of: element)
        return """
            if (bits < 0 || bits >= \(element.bits)) {
              return \(zero);
            }
            return \(shifted);
            """
    },
    Op("shiftedRight", "ShiftRightSame", [.vector, .shiftAmount], .vector, .integer) { element in
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
    Op("lessThan", "Lt", [.vector, .vector], .mask, .all) { element in
        "return (\(element.cMask))(a < b);"
    },
    Op("greaterThan", "Gt", [.vector, .vector], .mask, .all) { element in
        "return (\(element.cMask))(a > b);"
    },

    Op("selecting", "IfThenElse", [.mask, .vector, .vector], .vector, .all) { element in
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
    Op("allTrue", "AllTrue", [.tag, .mask], .boolean, .all) { _ in
        "return __builtin_reduce_and(mask) != 0;"
    },
    Op("allFalse", "AllFalse", [.tag, .mask], .boolean, .all) { _ in
        "return __builtin_reduce_or(mask) == 0;"
    },
    Op("trueCount", "CountTrue", [.tag, .mask], .count, .all) { _ in
        "return (size_t)-__builtin_reduce_add(mask);"
    },
    Op("firstTrueIndex", "FindFirstTrue", [.tag, .mask], .index, .all) { element in
        """
        for (size_t i = 0; i < \(element.laneCount); ++i) {
          if (mask[i]) {
            return (intptr_t)i;
          }
        }
        return -1;
        """
    },

    Op("sum", "ReduceSum", [.tag, .vector], .lane, .all(bits: [16, 32, 64])) { element in
        guard element.category == .float else { return "return __builtin_reduce_add(a);" }
        return """
            \(element.cType) sum = 0;
            for (size_t i = 0; i < \(element.laneCount); ++i) {
              sum += a[i];
            }
            return sum;
            """
    },
    Op("smallest", "ReduceMin", [.tag, .vector], .lane, .all(bits: [16, 32, 64])) { element in
        reducedExtremum("min", comparing: "<", from: infinity(of: element), for: element)
    },
    Op("largest", "ReduceMax", [.tag, .vector], .lane, .all(bits: [16, 32, 64])) { element in
        reducedExtremum("max", comparing: ">", from: "-\(infinity(of: element))", for: element)
    },
    Op("firstLane", "GetLane", [.vector], .lane, .all) { _ in
        "return a[0];"
    },

    Op("reversed", "Reverse", [.tag, .vector], .vector, .all) { element in
        let indices = (0..<element.laneCount).reversed().map(String.init)
        return "return __builtin_shufflevector(a, a, \(indices.joined(separator: ", ")));"
    },
    Op("slideUpLanes", "SlideUpLanes", [.tag, .vector, .laneAmount], .vector, .all) { element in
        """
        \(element.cVector) result = {0};
        for (size_t i = lanes; i < \(element.laneCount); ++i) {
          result[i] = a[i - lanes];
        }
        return result;
        """
    },
    Op("slide1Up", "Slide1Up", [.tag, .vector], .vector, .all) { element in
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
        .integer(bits: [8])
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
        span: .vectors(2)
    ) { element in
        loadInterleaved(channels: 2, for: element)
    },
    Op(
        "loadInterleaved3",
        "LoadInterleaved3",
        [.tag, .constLanePointer, .outVector, .outVector, .outVector],
        .void,
        .all,
        span: .vectors(3)
    ) { element in
        loadInterleaved(channels: 3, for: element)
    },
    Op(
        "loadInterleaved4",
        "LoadInterleaved4",
        [.tag, .constLanePointer, .outVector, .outVector, .outVector, .outVector],
        .void,
        .all,
        span: .vectors(4)
    ) { element in
        loadInterleaved(channels: 4, for: element)
    },
    Op(
        "storeInterleaved2",
        "StoreInterleaved2",
        [.vector, .vector, .tag, .lanePointer],
        .void,
        .all,
        span: .vectors(2)
    ) { element in
        storeInterleaved(channels: 2, for: element)
    },
    Op(
        "storeInterleaved3",
        "StoreInterleaved3",
        [.vector, .vector, .vector, .tag, .lanePointer],
        .void,
        .all,
        span: .vectors(3)
    ) { element in
        storeInterleaved(channels: 3, for: element)
    },
    Op(
        "storeInterleaved4",
        "StoreInterleaved4",
        [.vector, .vector, .vector, .vector, .tag, .lanePointer],
        .void,
        .all,
        span: .vectors(4)
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

    var span: SpanExtent { takesCount ? .first : .vectors(1) }
}

let wideningOps: [WideningOp] = [
    WideningOp(swiftName: "loadWidening", highwayName: "LoadU", takesCount: false),
    WideningOp(swiftName: "loadFirstWidening", highwayName: "LoadN", takesCount: true),
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

func bindings(of op: Op, for element: Element) -> [Binding] {
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
                    swiftType: "Vector",
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
                    swiftType: "Mask",
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
                    swiftType: "Lane",
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
                    swiftType: "UnsafePointer<Lane>",
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
                    swiftType: "UnsafeMutablePointer<Lane>",
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
                    swiftType: "Vector",
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

func swiftReturnType(_ returns: ReturnType) -> String {
    switch returns {
    case .vector: return "Vector"
    case .mask: return "Mask"
    case .lane: return "Lane"
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

func wideningBody(_ op: WideningOp, from narrow: Element, to wide: Element) -> String {
    let lanes = wide.laneCount
    let bytes = lanes * narrow.bits / 8
    let declaration = op.takesCount ? "narrow_vector v = {0};" : "narrow_vector v;"
    let size =
        op.takesCount
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

func cFunction(returns: String, name: String, parameters: [String], body: String) -> String {
    let signature = parameters.isEmpty ? "void" : parameters.joined(separator: ", ")
    let lines = body.split(separator: "\n", omittingEmptySubsequences: false).map { "  \($0)" }
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
                body: op.portable(element)
            )
        }

        for op in wideningOps {
            for narrow in wideningSources(of: element) {
                let countParameters = op.takesCount ? ["size_t count"] : []
                output += cFunction(
                    returns: element.cVector,
                    name: cWideningFunctionName(op, from: narrow, to: element),
                    parameters: ["const \(narrow.cType)* from"] + countParameters,
                    body: wideningBody(op, from: narrow, to: element)
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
    case .shiftAmount: return "Int32(\(binding.swiftName))"
    case .outVector: return "&\(binding.swiftName)"
    default: return binding.swiftName
    }
}

func swiftDeclaration(_ binding: Binding) -> String {
    let label = binding.swiftLabel ?? binding.swiftName
    let inoutKeyword = binding.isInOut ? "inout " : ""
    let naming =
        label == binding.swiftName
        ? binding.swiftName
        : "\(label) \(binding.swiftName)"
    return "\(naming): \(inoutKeyword)\(binding.swiftType)"
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

func portCall(_ name: String, _ arguments: [String]) -> String {
    "H.\(name)(\(arguments.joined(separator: ", ")))"
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
    port: String,
    reference: String,
    description: String
) -> String {
    let results = "(\(port), \(reference))"
    let scope =
        aligned
        ? "unsafe withAlignedLanes(\(source)) { source in \(results) }.result"
        : "\(source).withUnsafeBufferPointer { source in \(results) }"
    return """
        let (portResult, referenceResult) = \(scope)
        mismatches.check(portResult, referenceResult, \(description))
        """
}

func referenceOutVectorStatements(
    of source: String,
    count: Int,
    for element: Element,
    port: String,
    reference: String,
    inputs: [ReferenceInput]
) -> String {
    let zero = referenceCall(referenceFunctionName("zero", element), [])
    var statements = (0..<count).map { "var p\($0) = \(portCall("zero", []))" }
    statements += (0..<count).map { "var r\($0) = \(zero)" }
    statements.append("\(source).withUnsafeBufferPointer { source in\n\(port)\n\(reference)\n}")
    for index in 0..<count {
        let description = referenceDescription(of: inputs, suffix: ", v\(index)")
        statements.append("mismatches.check(p\(index), port(r\(index)), \(description))")
    }
    return statements.joined(separator: "\n")
}

func referenceStoreStatements(
    aligned: Bool,
    port: String,
    reference: String,
    description: String
) -> String {
    let stores = [("portLanes", port), ("referenceLanes", reference)].map { lanes, call in
        let closure = "{ destination in \(call) }"
        return aligned
            ? "let \(lanes) = unsafe withAlignedLanes(sentinel) \(closure).lanes"
            : "var \(lanes) = sentinel\n\(lanes).withUnsafeMutableBufferPointer \(closure)"
    }
    let comparison = "mismatches.check(portLanes, referenceLanes, \(description))"
    return (stores + [comparison]).joined(separator: "\n")
}

func referenceTest(of op: Op, for element: Element, inContract: Bool) -> String {
    let test = inContract ? op.swiftName : "\(op.swiftName)OutOfContract"
    let inputs = referenceInputs(of: op, for: element, test: test, inContract: inContract)
    let description = referenceDescription(of: inputs)
    let aligned = isAligned(op)
    let isStore = op.parameters.contains(.lanePointer)
    let pointer = pointerExpression(isStore ? "destination" : "source", aligned: aligned)
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
                port: calls.port,
                reference: calls.reference,
                description: description
            )
            : referenceOutVectorStatements(
                of: source,
                count: outVectors,
                for: element,
                port: calls.port,
                reference: calls.reference,
                inputs: inputs
            )
    } else if isStore {
        let lanes = pointerLanes(of: op, for: element)
        declarations.append("let sentinel = Inputs.sentinel(H.Lane.self, count: \(lanes) + 4)")
        statements = referenceStoreStatements(
            aligned: aligned,
            port: calls.port,
            reference: calls.reference,
            description: description
        )
    } else {
        statements = "mismatches.check(\(calls.port), \(calls.reference), \(description))"
    }

    return referenceTestFunction(
        test,
        label: inContract ? op.swiftName : "\(op.swiftName) out of contract",
        for: element,
        inputs: inputs,
        declarations: declarations,
        disabledOnEmulation: !inContract && op.parameters.contains(.shiftAmount),
        statements: statements
    )
}

func wideningReferenceTest(_ op: WideningOp, from narrow: Element, to wide: Element) -> String {
    let test = "\(op.swiftName)From\(narrow.swiftType)"
    let seed = "seed: \(referenceTestSeed(wide, test, "0"))"
    var inputs = [
        ReferenceInput(
            parameter: .constLanePointer,
            name: "from",
            values: "Inputs.buffers(\(narrow.swiftType).self, count: H.laneCount, \(seed))"
        )
    ]
    var portArguments = ["from: source.baseAddress!"]
    var referenceArguments = ["source.baseAddress!"]
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
    return referenceTestFunction(
        test,
        label: "\(op.swiftName) from \(narrow.swiftType)",
        for: wide,
        inputs: inputs,
        statements: referenceLoadStatements(
            of: "from",
            aligned: false,
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
    }
    for op in wideningOps {
        for narrow in wideningSources(of: element) {
            tests.append(wideningReferenceTest(op, from: narrow, to: element))
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
try write(generateHeader(), to: headerPath)
try write(generateReferenceHeader(), to: referenceHeaderPath)
try write(generateProtocols(), to: "\(generatedSwiftRoot)/HighwayElement.swift")
for element in elements {
    try write(generateElement(element), to: "\(generatedSwiftRoot)/\(element.namespace).swift")
    try write(
        generateReferenceTests(element),
        to: "\(generatedReferenceTestsRoot)/\(element.namespace)ReferenceTests.swift"
    )
}
try format(generatedSwiftRoot)
try format(generatedReferenceTestsRoot)
FileHandle.standardError.write(
    Data("** ✅ Generated \(elements.count) element types.\n".utf8)
)
