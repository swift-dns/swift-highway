internal import CHighwayOps

/// Runtime information about the Highway target this package was compiled for.
///
/// The ops are compiled for a static target, so the target is the best one the compiler was
/// told it could use, rather than one chosen at run time. On arm64 that is NEON, which is
/// baseline. On x86_64 the baseline is SSE2, or SSSE3 on Apple platforms and Android, and SSE4,
/// which needs SSE4.2, is the most a caller can get, with `-Xcc -march=x86-64-v2`.
public enum Highway: SendableMetatype {
    /// The name of the target the ops were compiled for, such as `NEON` or `SSE4`.
    public static var targetName: String {
        unsafe String(cString: chighway_ops_target_name())
    }

    /// Whether the target only emulates vectors, in which case scalar code is faster.
    public static var isEmulated: Bool {
        chighway_ops_is_emulated()
    }
}

@available(*, unavailable)
extension Highway: Sendable {}
