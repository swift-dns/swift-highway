#if $Embedded || os(WASI)
import Testing

@Suite("Unavailable")
struct UnavailableTests {
    @Test("Highway has no test on embedded and WASI targets")
    func placeholder() {}
}
#endif
