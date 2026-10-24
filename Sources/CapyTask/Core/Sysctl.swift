import Darwin

enum Sysctl {
    static func read<T: FixedWidthInteger>(_ name: String, as type: T.Type = T.self) -> T? {
        var value: T = 0
        var size = MemoryLayout<T>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }

    static func string(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
    }

    static func swapUsage() -> xsw_usage? {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return nil }
        return usage
    }
}

/// `mach_host_self()` devuelve un derecho de envío nuevo en cada llamada;
/// lo pedimos una sola vez para no filtrar referencias de puerto.
enum HostPort {
    static let shared: host_t = mach_host_self()
}
