// Generates the C++ bridge header and the Swift layer over it, from the op list below.
//
// Run from the repository root:
//
//     swift utils/GenerateHighwayOps.swift
//
// Every op needs a bridge, even one whose arguments are only vectors: the namespace the ops
// live in is HWY_NAMESPACE, which expands to the static target's name, and Swift has no macro
// with which to spell it.

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

    init(
        _ swiftName: String,
        _ highwayName: String,
        _ parameters: [Parameter],
        _ returns: ReturnType,
        _ applies: Applies,
        _ documentation: String = "",
        span: SpanExtent? = nil
    ) {
        self.swiftName = swiftName
        self.highwayName = highwayName
        self.parameters = parameters
        self.returns = returns
        self.applies = applies
        self.documentation = documentation
        self.span = span
    }
}

let ops: [Op] = [
    Op("zero", "Zero", [.tag], .vector, .all),
    Op("repeating", "Set", [.tag, .lane], .vector, .all),
    Op("iota", "Iota", [.tag, .lane], .vector, .all),

    Op("load", "LoadU", [.tag, .constLanePointer], .vector, .all, span: .vectors(1)),
    Op(
        "loadAligned",
        "Load",
        [.tag, .constLanePointer],
        .vector,
        .all,
        span: .vectors(1, aligned: true)
    ),
    Op("loadFirst", "LoadN", [.tag, .constLanePointer, .count], .vector, .all, span: .first),
    Op("store", "StoreU", [.vector, .tag, .lanePointer], .void, .all, span: .vectors(1)),
    Op(
        "storeAligned",
        "Store",
        [.vector, .tag, .lanePointer],
        .void,
        .all,
        span: .vectors(1, aligned: true)
    ),
    Op("storeFirst", "StoreN", [.vector, .tag, .lanePointer, .count], .void, .all, span: .first),

    Op("adding", "Add", [.vector, .vector], .vector, .all),
    Op("subtracting", "Sub", [.vector, .vector], .vector, .all),
    Op("multiplying", "Mul", [.vector, .vector], .vector, .all(bits: [16, 32, 64])),
    Op("dividing", "Div", [.vector, .vector], .vector, .float),
    Op("minimum", "Min", [.vector, .vector], .vector, .all),
    Op("maximum", "Max", [.vector, .vector], .vector, .all),
    Op("negated", "Neg", [.vector], .vector, .signedOrFloat),
    Op("magnitude", "Abs", [.vector], .vector, .signedOrFloat),
    Op("squareRoot", "Sqrt", [.vector], .vector, .float),
    Op("multiplyAdding", "MulAdd", [.vector, .vector, .vector], .vector, .float),
    Op("saturatingAdding", "SaturatedAdd", [.vector, .vector], .vector, .integer(bits: [8, 16])),
    Op(
        "saturatingSubtracting",
        "SaturatedSub",
        [.vector, .vector],
        .vector,
        .integer(bits: [8, 16])
    ),
    Op("roundedAverage", "AverageRound", [.vector, .vector], .vector, .unsigned(bits: [8, 16])),

    Op("bitwiseAnd", "And", [.vector, .vector], .vector, .integer),
    Op("bitwiseOr", "Or", [.vector, .vector], .vector, .integer),
    Op("bitwiseXor", "Xor", [.vector, .vector], .vector, .integer),
    Op("bitwiseNot", "Not", [.vector], .vector, .integer),
    Op("bitwiseAndNot", "AndNot", [.vector, .vector], .vector, .integer),

    Op("shiftedLeft", "ShiftLeftSame", [.vector, .shiftAmount], .vector, .integer),
    Op("shiftedRight", "ShiftRightSame", [.vector, .shiftAmount], .vector, .integer),

    Op("equalTo", "Eq", [.vector, .vector], .mask, .all),
    Op("notEqualTo", "Ne", [.vector, .vector], .mask, .all),
    Op("lessThan", "Lt", [.vector, .vector], .mask, .all),
    Op("greaterThan", "Gt", [.vector, .vector], .mask, .all),

    Op("selecting", "IfThenElse", [.mask, .vector, .vector], .vector, .all),
    Op("selectingOrZero", "IfThenElseZero", [.mask, .vector], .vector, .all),
    Op("zeroingSelected", "IfThenZeroElse", [.mask, .vector], .vector, .all),
    Op("firstLanes", "FirstN", [.tag, .count], .mask, .all),
    Op("allTrue", "AllTrue", [.tag, .mask], .boolean, .all),
    Op("allFalse", "AllFalse", [.tag, .mask], .boolean, .all),
    Op("trueCount", "CountTrue", [.tag, .mask], .count, .all),
    Op("firstTrueIndex", "FindFirstTrue", [.tag, .mask], .index, .all),

    Op("sum", "ReduceSum", [.tag, .vector], .lane, .all(bits: [16, 32, 64])),
    Op("smallest", "ReduceMin", [.tag, .vector], .lane, .all(bits: [16, 32, 64])),
    Op("largest", "ReduceMax", [.tag, .vector], .lane, .all(bits: [16, 32, 64])),
    Op("firstLane", "GetLane", [.vector], .lane, .all),

    Op("reversed", "Reverse", [.tag, .vector], .vector, .all),
    Op("slideUpLanes", "SlideUpLanes", [.tag, .vector, .laneAmount], .vector, .all),
    Op("slide1Up", "Slide1Up", [.tag, .vector], .vector, .all),
    Op("tableLookupBytes", "TableLookupBytes", [.vector, .vector], .vector, .integer(bits: [8])),

    Op(
        "loadInterleaved2",
        "LoadInterleaved2",
        [.tag, .constLanePointer, .outVector, .outVector],
        .void,
        .all,
        span: .vectors(2)
    ),
    Op(
        "loadInterleaved3",
        "LoadInterleaved3",
        [.tag, .constLanePointer, .outVector, .outVector, .outVector],
        .void,
        .all,
        span: .vectors(3)
    ),
    Op(
        "loadInterleaved4",
        "LoadInterleaved4",
        [.tag, .constLanePointer, .outVector, .outVector, .outVector, .outVector],
        .void,
        .all,
        span: .vectors(4)
    ),
    Op(
        "storeInterleaved2",
        "StoreInterleaved2",
        [.vector, .vector, .tag, .lanePointer],
        .void,
        .all,
        span: .vectors(2)
    ),
    Op(
        "storeInterleaved3",
        "StoreInterleaved3",
        [.vector, .vector, .vector, .tag, .lanePointer],
        .void,
        .all,
        span: .vectors(3)
    ),
    Op(
        "storeInterleaved4",
        "StoreInterleaved4",
        [.vector, .vector, .vector, .vector, .tag, .lanePointer],
        .void,
        .all,
        span: .vectors(4)
    ),
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

let repeatingBlockName = "repeatingBlock"

/// The parameters of `repeatingBlock`, one per lane of a 128-bit block.
func repeatingBlockLanes(of element: Element) -> [String] {
    (0..<(128 / element.bits)).map { "v\($0)" }
}

struct Binding {
    let declaration: String
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
                    argument: "\(element.tag)()",
                    swiftLabel: nil,
                    swiftName: "",
                    swiftType: "",
                    isInOut: false
                )
            )
        case .vector:
            let name = vectorNames.next() ?? "v"
            result.append(
                Binding(
                    declaration: "\(element.vector) \(name)",
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

func cReturnType(_ returns: ReturnType, _ element: Element) -> String {
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

let unavailabilityMessage =
    "Highway needs C++ interoperability, which embedded Swift and WASI do not properly support"

let unavailableAttribute = """
    @available(
        *,
        unavailable,
        message:
            "\(unavailabilityMessage)"
    )
    """

func unavailableSendableConformance(of type: String) -> String {
    """
    @available(*, unavailable)
    extension \(type): Sendable {}
    """
}

/// Embedded Swift has no C++ interoperability, and the WASI SDK's own modules cycle under it, so
/// every type the ops are reached through is declared unavailable there rather than compiled.
func generateFile(unavailable: String, available: String) -> String {
    """
    \(generationNotice)

    #if $Embedded || os(WASI)
    \(unavailable)
    #else
    \(available)
    #endif

    """
}

func generateHeader() -> String {
    var output = """
        \(generationNotice)

        #ifndef SWIFT_HIGHWAY_OPS_H
        #define SWIFT_HIGHWAY_OPS_H

        #include <stddef.h>
        #include <stdint.h>

        // HWY_DISABLED_TARGETS is set by the build, see Package.swift.
        #include "hwy/highway.h"

        namespace HighwayOps {
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
        output += "HWY_INLINE size_t laneCount\(element.suffix)()"
        output += " { return hn::Lanes(\(element.tag)()); }\n"

        for op in ops where op.applies.matches(element) {
            let parameterBindings = bindings(of: op, for: element)
            let declarations =
                parameterBindings
                .filter { !$0.declaration.isEmpty }
                .map(\.declaration)
                .joined(separator: ", ")
            let arguments = parameterBindings.map(\.argument).joined(separator: ", ")
            let returnKeyword = op.returns == .void ? "" : "return "
            output += "HWY_INLINE \(cReturnType(op.returns, element)) "
            output += "\(op.swiftName)\(element.suffix)(\(declarations))"
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
        output += "HWY_INLINE \(element.vector) \(repeatingBlockName)\(element.suffix)("
        output += blockLanes.map { "\(element.cType) \($0)" }.joined(separator: ", ")
        output += ") { return hn::Dup128VecFromValues(\(element.tag)(), "
        output += "\(blockLanes.joined(separator: ", "))); }\n"
        output += "\n"
    }

    output += """
        }  // namespace HighwayOps

        #endif

        """
    return output
}

func swiftArgument(_ binding: Binding, _ parameter: Parameter) -> String {
    switch parameter {
    case .tag: return ""
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

/// How a Swift call passes `binding` on to a function that has the same parameter.
func swiftCallArgument(_ binding: Binding) -> String {
    let label = binding.swiftLabel ?? binding.swiftName
    let value = binding.isInOut ? "&\(binding.swiftName)" : binding.swiftName
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
    let call = "\(keyword)HighwayOps.\(op.swiftName)\(element.suffix)(\(arguments))"
    switch op.returns {
    case .count, .index: return "Int(\(call))"
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
    let function = wideningFunctionName(op, from: narrow, to: wide)
    return SpanForms(
        name: op.swiftName,
        parameters: [.span],
        returns: .vector,
        extent: op.span,
        element: narrow.swiftType,
        isMutable: false,
        bridgeCall: { pointer, count in
            let countArgument = op.takesCount ? ", \(count)" : ""
            return "unsafe HighwayOps.\(function)(\(pointer)\(countArgument))"
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
    let available = """
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

    return generateFile(
        unavailable: """
            \(unavailableAttribute)
            public protocol HighwayElement {}

            \(unavailableAttribute)
            public protocol HighwayIntegerElement {}

            \(unavailableAttribute)
            public protocol HighwayFloatElement {}
            """,
        available: available
    )
}

func generateElement(_ element: Element) -> String {
    var conformances = ["HighwayElement"]
    if element.category == .float {
        conformances.append("HighwayFloatElement")
    } else {
        conformances.append("HighwayIntegerElement")
    }
    conformances.append("SendableMetatype")

    var available = """
        internal import CHighwayOps

        /// Highway's vectors of `\(element.swiftType)`, and the ops over them.
        public enum \(element.namespace): \(conformances.joined(separator: ", ")) {
            public typealias Lane = \(element.swiftType)
            public typealias Vector = HighwayOps.\(element.vector)
            public typealias Mask = HighwayOps.\(element.mask)

            @export(implementation) @inline(always)
            public static var laneCount: Int { Int(HighwayOps.laneCount\(element.suffix)()) }


        """

    for op in ops where op.applies.matches(element) {
        let signature = swiftSignature(of: op, for: element)
        let returnClause = op.returns == .void ? "" : " -> \(swiftReturnType(op.returns))"
        let body = swiftBody(of: op, for: element, arguments: signature.arguments)
        available += "    @export(implementation) @inline(always)\n"
        available +=
            "    public static func \(op.swiftName)(\(signature.parameters))\(returnClause) {\n"
        available += "        \(body)\n"
        available += "    }\n\n"
        if let forms = spanForms(of: op, for: element) {
            available += spanMembers(forms)
            if forms.isMutable {
                available += outputSpanMembers(forms)
            }
        }
    }

    for op in wideningOps {
        for narrow in wideningSources(of: element) {
            let countParameter = op.takesCount ? ", count: Int" : ""
            let countArgument = op.takesCount ? ", count" : ""
            let function = wideningFunctionName(op, from: narrow, to: element)
            available += "    @export(implementation) @inline(always)\n"
            available += "    public static func \(op.swiftName)("
            available += "from: UnsafePointer<\(narrow.swiftType)>\(countParameter)"
            available += ") -> Vector {\n"
            available += "        unsafe HighwayOps.\(function)(from\(countArgument))\n"
            available += "    }\n\n"
            available += spanMembers(spanForms(of: op, from: narrow, to: element))
        }
    }

    let blockLanes = repeatingBlockLanes(of: element)
    available += "    @export(implementation) @inline(always)\n"
    available += "    public static func \(repeatingBlockName)("
    available += blockLanes.map { "_ \($0): Lane" }.joined(separator: ", ")
    available += ") -> Vector {\n"
    available += "        HighwayOps.\(repeatingBlockName)\(element.suffix)("
    available += "\(blockLanes.joined(separator: ", ")))\n"
    available += "    }\n\n"

    available += "}\n\n\(unavailableSendableConformance(of: element.namespace))\n"

    return generateFile(
        unavailable: """
            \(unavailableAttribute)
            public enum \(element.namespace): SendableMetatype {}

            \(unavailableSendableConformance(of: element.namespace))
            """,
        available: available
    )
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

struct SortableElement {
    let cType: String
    let swiftType: String
}

// float16_t, K32V32, K64V64 and uint128_t are left out until they have Swift types to sort.
let sortableElements: [SortableElement] = [
    SortableElement(cType: "uint16_t", swiftType: "UInt16"),
    SortableElement(cType: "uint32_t", swiftType: "UInt32"),
    SortableElement(cType: "uint64_t", swiftType: "UInt64"),
    SortableElement(cType: "int16_t", swiftType: "Int16"),
    SortableElement(cType: "int32_t", swiftType: "Int32"),
    SortableElement(cType: "int64_t", swiftType: "Int64"),
    SortableElement(cType: "float", swiftType: "Float"),
    SortableElement(cType: "double", swiftType: "Double"),
]

struct SortOperation {
    let swiftName: String
    let highwayName: String
    let takesCount: Bool
    let countLabel: String
    let documentation: String
    var countName = "count"
    var countIsIndex = false
}

let sortOperations: [SortOperation] = [
    SortOperation(
        swiftName: "sort",
        highwayName: "VQSort",
        takesCount: false,
        countLabel: "",
        documentation: "Sorts `keys` in place with Highway's vectorized quicksort."
    ),
    SortOperation(
        swiftName: "partialSort",
        highwayName: "VQPartialSort",
        takesCount: true,
        countLabel: "keeping",
        documentation: """
            Orders `keys` so that its first `count` elements are the ones a full sort would
            put there, in the order a full sort would put them in.
            """
    ),
    SortOperation(
        swiftName: "select",
        highwayName: "VQSelect",
        takesCount: true,
        countLabel: "at",
        documentation: """
            Orders `keys` so that the element at `index` is the one a full sort would put
            there, and no element before it compares after it.
            """,
        countName: "index",
        countIsIndex: true
    ),
]

// What `Highway`'s sorting functions take keys as. Over a span, an operation that takes a count
// has a checked form and an `@unsafe` unchecked one, like the span forms of the ops.
struct SortKeys {
    let type: String
    let availability: String?
    let checksCount: Bool
}

let sortKeys: [SortKeys] = [
    SortKeys(type: "[Key]", availability: nil, checksCount: false),
    SortKeys(type: "MutableSpan<Key>", availability: spanAvailability, checksCount: true),
]

func sortSignature(_ operation: SortOperation, elementType: String) -> String {
    var parameters = "_ keys: UnsafeMutableBufferPointer<\(elementType)>"
    if operation.takesCount {
        parameters += ", \(operation.countLabel) count: Int"
    }
    parameters += ", order: SortOrder"
    return parameters
}

func sortMember(
    _ operation: SortOperation,
    keys: SortKeys,
    documentation: String,
    isUnsafe: Bool,
    countLabel: String,
    body: [String]
) -> String {
    var lines = documentation.split(separator: "\n").map { "/// \($0)" }
    if let availability = keys.availability {
        lines.append(availability)
    }
    lines.append(isUnsafe ? "@unsafe @export(implementation)" : "@export(implementation)")
    lines.append("public static func \(operation.swiftName)<Key: HighwaySortable>(")
    lines.append("    _ keys: inout \(keys.type),")
    if operation.takesCount {
        lines.append("    \(countLabel) \(operation.countName): Int,")
    }
    lines.append("    order: SortOrder = .ascending")
    lines.append(") {")
    lines += body.map { "    \($0)" }
    lines.append("}")
    return lines.map { "    \($0)" }.joined(separator: "\n")
}

/// The members of `extension Highway` that apply `operation` to `keys`, through the
/// `HighwaySortable` requirement of the same name.
func sortMembers(_ operation: SortOperation, keys: SortKeys) -> [String] {
    let arguments =
        operation.takesCount
        ? "$0, \(operation.countLabel): \(operation.countName), order: order"
        : "$0, order: order"
    let sortCall =
        "keys.withUnsafeMutableBufferPointer { unsafe Key.\(operation.swiftName)(\(arguments)) }"

    guard operation.takesCount, keys.checksCount else {
        return [
            sortMember(
                operation,
                keys: keys,
                documentation: operation.documentation,
                isUnsafe: false,
                countLabel: operation.countLabel,
                body: [sortCall]
            )
        ]
    }

    let name = operation.countName
    let uncheckedLabel = "\(operation.countLabel)Unchecked"
    let condition = "\(name) >= 0 && \(name) \(operation.countIsIndex ? "<" : "<=") keys.count"
    let message = operation.countIsIndex ? "Index out of bounds" : "Count out of bounds"
    let uncheckedCall =
        "unsafe \(operation.swiftName)(&keys, \(uncheckedLabel): \(name), order: order)"
    let uncheckedDocumentation =
        "Like `\(operation.swiftName)(_:\(operation.countLabel):order:)`, "
        + "but only checks `\(name)` in debug builds."

    return [
        sortMember(
            operation,
            keys: keys,
            documentation: operation.documentation,
            isUnsafe: false,
            countLabel: operation.countLabel,
            body: ["precondition(\(condition), \"\(message)\")", uncheckedCall]
        ),
        sortMember(
            operation,
            keys: keys,
            documentation: uncheckedDocumentation,
            isUnsafe: true,
            countLabel: uncheckedLabel,
            body: ["assert(\(condition), \"\(message)\")", sortCall]
        ),
    ]
}

func generateSortable() -> String {
    var available = """
        internal import CHighway

        /// The direction `Highway.sort(_:order:)` and its neighbours order keys in.
        public enum SortOrder: Sendable {
            case ascending
            case descending
        }

        /// A key type that Highway's vectorized sort supports.
        ///
        /// Unlike the ops, sorting picks its target at run time, so it uses the best target the
        /// processor has rather than the one the compiler was told to assume.
        public protocol HighwaySortable {

        """

    for operation in sortOperations {
        available += "    static func \(operation.swiftName)("
        available += "\(sortSignature(operation, elementType: "Self")))\n"
    }
    available += "}\n"

    for element in sortableElements {
        available += """

            extension \(element.swiftType): HighwaySortable {

            """
        for operation in sortOperations {
            let arguments =
                operation.takesCount ? "base, keys.count, count, " : "base, keys.count, "
            available += """
                    public static func \(operation.swiftName)(
                        \(sortSignature(operation, elementType: element.swiftType))
                    ) {
                        guard let base = keys.baseAddress, keys.count > 1 else { return }
                        switch order {
                        case .ascending:
                            unsafe hwy.\(operation.highwayName)(\(arguments)hwy.SortAscending())
                        case .descending:
                            unsafe hwy.\(operation.highwayName)(\(arguments)hwy.SortDescending())
                        }
                    }

                """
        }
        available += "}\n"
    }

    let members = sortOperations.flatMap { operation in
        sortKeys.flatMap { keys in sortMembers(operation, keys: keys) }
    }
    available += """

        extension Highway {
        \(members.joined(separator: "\n\n"))
        }

        """

    return generateFile(
        unavailable: """
            \(unavailableAttribute)
            public enum SortOrder: Sendable {}

            \(unavailableAttribute)
            public protocol HighwaySortable {}
            """,
        available: available
    )
}

let repositoryRoot = FileManager.default.currentDirectoryPath
let headerPath = "\(repositoryRoot)/Sources/CHighwayOps/include/CHighwayOps.h"
let generatedSwiftRoot = "\(repositoryRoot)/Sources/Highway/Generated"

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
try write(generateHeader(), to: headerPath)
try write(generateProtocols(), to: "\(generatedSwiftRoot)/HighwayElement.swift")
try write(generateSortable(), to: "\(generatedSwiftRoot)/HighwaySortable.swift")
for element in elements {
    try write(generateElement(element), to: "\(generatedSwiftRoot)/\(element.namespace).swift")
}
try format(generatedSwiftRoot)
FileHandle.standardError.write(
    Data("** ✅ Generated \(elements.count) element types.\n".utf8)
)
