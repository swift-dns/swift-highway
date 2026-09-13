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

struct Op {
    let swiftName: String
    let highwayName: String
    let parameters: [Parameter]
    let returns: ReturnType
    let applies: Applies
    var documentation: String = ""

    init(
        _ swiftName: String,
        _ highwayName: String,
        _ parameters: [Parameter],
        _ returns: ReturnType,
        _ applies: Applies,
        _ documentation: String = ""
    ) {
        self.swiftName = swiftName
        self.highwayName = highwayName
        self.parameters = parameters
        self.returns = returns
        self.applies = applies
        self.documentation = documentation
    }
}

let ops: [Op] = [
    Op("zero", "Zero", [.tag], .vector, .all),
    Op("repeating", "Set", [.tag, .lane], .vector, .all),
    Op("iota", "Iota", [.tag, .lane], .vector, .all),

    Op("load", "LoadU", [.tag, .constLanePointer], .vector, .all),
    Op("loadAligned", "Load", [.tag, .constLanePointer], .vector, .all),
    Op("loadFirst", "LoadN", [.tag, .constLanePointer, .count], .vector, .all),
    Op("store", "StoreU", [.vector, .tag, .lanePointer], .void, .all),
    Op("storeAligned", "Store", [.vector, .tag, .lanePointer], .void, .all),
    Op("storeFirst", "StoreN", [.vector, .tag, .lanePointer, .count], .void, .all),

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
    Op("tableLookupBytes", "TableLookupBytes", [.vector, .vector], .vector, .integer(bits: [8])),

    Op(
        "loadInterleaved2",
        "LoadInterleaved2",
        [.tag, .constLanePointer, .outVector, .outVector],
        .void,
        .all
    ),
    Op(
        "loadInterleaved3",
        "LoadInterleaved3",
        [.tag, .constLanePointer, .outVector, .outVector, .outVector],
        .void,
        .all
    ),
    Op(
        "loadInterleaved4",
        "LoadInterleaved4",
        [.tag, .constLanePointer, .outVector, .outVector, .outVector, .outVector],
        .void,
        .all
    ),
    Op(
        "storeInterleaved2",
        "StoreInterleaved2",
        [.vector, .vector, .tag, .lanePointer],
        .void,
        .all
    ),
    Op(
        "storeInterleaved3",
        "StoreInterleaved3",
        [.vector, .vector, .vector, .tag, .lanePointer],
        .void,
        .all
    ),
    Op(
        "storeInterleaved4",
        "StoreInterleaved4",
        [.vector, .vector, .vector, .vector, .tag, .lanePointer],
        .void,
        .all
    ),
]

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

func swiftSignature(of op: Op, for element: Element) -> (parameters: String, arguments: String) {
    let parameterBindings = bindings(of: op, for: element)
    var declarations: [String] = []
    var arguments: [String] = []

    for (binding, parameter) in zip(parameterBindings, op.parameters) {
        if case .tag = parameter { continue }
        let label = binding.swiftLabel ?? binding.swiftName
        let inoutKeyword = binding.isInOut ? "inout " : ""
        let naming =
            label == binding.swiftName
            ? binding.swiftName
            : "\(label) \(binding.swiftName)"
        declarations.append("\(naming): \(inoutKeyword)\(binding.swiftType)")
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
    }
    return output
}

func generateProtocols() -> String {
    """
    \(generationNotice)

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
}

func generateElement(_ element: Element) -> String {
    var conformances = ["HighwayElement"]
    if element.category == .float {
        conformances.append("HighwayFloatElement")
    } else {
        conformances.append("HighwayIntegerElement")
    }

    var output = """
        \(generationNotice)

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
        output += "    @export(implementation) @inline(always)\n"
        output +=
            "    public static func \(op.swiftName)(\(signature.parameters))\(returnClause) {\n"
        output += "        \(body)\n"
        output += "    }\n\n"
    }

    output += "}\n"
    return output
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
}

let sortOperations: [SortOperation] = [
    SortOperation(swiftName: "sort", highwayName: "VQSort", takesCount: false, countLabel: ""),
    SortOperation(
        swiftName: "partialSort",
        highwayName: "VQPartialSort",
        takesCount: true,
        countLabel: "keeping"
    ),
    SortOperation(
        swiftName: "select",
        highwayName: "VQSelect",
        takesCount: true,
        countLabel: "at"
    ),
]

func sortSignature(_ operation: SortOperation, elementType: String) -> String {
    var parameters = "_ keys: UnsafeMutableBufferPointer<\(elementType)>"
    if operation.takesCount {
        parameters += ", \(operation.countLabel) count: Int"
    }
    parameters += ", order: SortOrder"
    return parameters
}

func generateSortable() -> String {
    var output = """
        \(generationNotice)

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
        output += "    static func \(operation.swiftName)("
        output += "\(sortSignature(operation, elementType: "Self")))\n"
    }
    output += "}\n"

    for element in sortableElements {
        output += """

            extension \(element.swiftType): HighwaySortable {

            """
        for operation in sortOperations {
            let arguments =
                operation.takesCount ? "base, keys.count, count, " : "base, keys.count, "
            output += """
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
        output += "}\n"
    }

    output += """

        extension Highway {
            /// Sorts `keys` in place with Highway's vectorized quicksort.
            @export(implementation)
            public static func sort<Key: HighwaySortable>(
                _ keys: inout [Key],
                order: SortOrder = .ascending
            ) {
                keys.withUnsafeMutableBufferPointer { unsafe Key.sort($0, order: order) }
            }

            /// Orders `keys` so that its first `count` elements are the ones a full sort would
            /// put there, in the order a full sort would put them in.
            @export(implementation)
            public static func partialSort<Key: HighwaySortable>(
                _ keys: inout [Key],
                keeping count: Int,
                order: SortOrder = .ascending
            ) {
                keys.withUnsafeMutableBufferPointer {
                    unsafe Key.partialSort($0, keeping: count, order: order)
                }
            }

            /// Orders `keys` so that the element at `index` is the one a full sort would put
            /// there, and no element before it compares after it.
            @export(implementation)
            public static func select<Key: HighwaySortable>(
                _ keys: inout [Key],
                at index: Int,
                order: SortOrder = .ascending
            ) {
                keys.withUnsafeMutableBufferPointer { unsafe Key.select($0, at: index, order: order) }
            }
        }

        """
    return output
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
