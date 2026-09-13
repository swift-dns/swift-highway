public import CHighwayOps

/// Runtime information about the Highway target this package was compiled for.
///
/// Highway is used here in static dispatch mode, so the target is the best one the compiler was
/// told it could use, rather than one chosen at run time. On arm64 that is NEON, which is
/// baseline. On x86_64 the baseline is SSE2, so a caller that wants more passes its own
/// `-Xcc -march=…`.
public enum Highway {
    /// The name of the target the ops were compiled for, such as `NEON` or `AVX3`.
    public static var targetName: String {
        unsafe String(cString: HighwayOps.targetName())
    }

    /// Whether the target only emulates vectors, in which case scalar code is faster.
    public static var isEmulated: Bool {
        HighwayOps.isEmulated()
    }
}
