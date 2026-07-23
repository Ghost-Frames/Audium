import Darwin

/// Whether this Mac has an Apple Neural Engine. WhisperKit's CoreML pipeline SIGSEGVs on Intel
/// before compute-unit dispatch even happens (docs/spec.md §5, Known Issues), and CoreML doesn't
/// expose a direct "has ANE" query — the actual determining factor is Apple Silicon vs. Intel, so
/// that's what this checks, via the same `hw.optional.arm64` sysctl macOS itself uses for that
/// distinction (1 when running natively on Apple Silicon, absent/0 on Intel).
enum HardwareCapability {
    static var hasNeuralEngine: Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let status = sysctlbyname("hw.optional.arm64", &value, &size, nil, 0)
        return status == 0 && value == 1
    }
}
