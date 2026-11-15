import Foundation
import Darwin

/// Whole-machine numbers for the cards above the process table.
public struct SystemCardsSnapshot: Equatable, Sendable {
    /// Average over all cores, 0…1.
    public let cpuFraction: Double
    public let perCoreFractions: [Double]
    public let memory: MemoryUsage
    public let disk: DiskUsage
    public let bytesInPerSecond: Double
    public let bytesOutPerSecond: Double

    public init(
        cpuFraction: Double,
        perCoreFractions: [Double],
        memory: MemoryUsage,
        disk: DiskUsage,
        bytesInPerSecond: Double,
        bytesOutPerSecond: Double
    ) {
        self.cpuFraction = cpuFraction
        self.perCoreFractions = perCoreFractions
        self.memory = memory
        self.disk = disk
        self.bytesInPerSecond = bytesInPerSecond
        self.bytesOutPerSecond = bytesOutPerSecond
    }
}

/// Reads the same kernel counters as the menu bar helper's collectors, plus
/// per-core CPU. CPU and network are rates, so the first sample reports 0.
public actor SystemCardsSampler {
    private var previousCores: [CPUTicks] = []
    private var previousNetwork: (bytesIn: UInt64, bytesOut: UInt64, at: TimeInterval)?

    public init() {}

    public func sample() -> SystemCardsSnapshot {
        let cores = readCores()
        let perCore: [Double]
        if cores.count == previousCores.count {
            perCore = zip(previousCores, cores).map { before, after in
                CPUUsage(previous: before, current: after)?.totalActiveFraction ?? 0
            }
        } else {
            perCore = Array(repeating: 0, count: cores.count)
        }
        previousCores = cores
        let cpu = perCore.isEmpty ? 0 : perCore.reduce(0, +) / Double(perCore.count)

        let network = readNetworkBytes()
        let now = ProcessInfo.processInfo.systemUptime
        var rateIn = 0.0
        var rateOut = 0.0
        if let before = previousNetwork {
            rateIn = NetworkRate.bytesPerSecond(current: network.bytesIn, previous: before.bytesIn, elapsed: now - before.at)
            rateOut = NetworkRate.bytesPerSecond(current: network.bytesOut, previous: before.bytesOut, elapsed: now - before.at)
        }
        previousNetwork = (network.bytesIn, network.bytesOut, now)

        return SystemCardsSnapshot(
            cpuFraction: cpu,
            perCoreFractions: perCore,
            memory: readMemory(),
            disk: readDisk(),
            bytesInPerSecond: rateIn,
            bytesOutPerSecond: rateOut
        )
    }

    private func readCores() -> [CPUTicks] {
        var cpuCount: natural_t = 0
        var cpuInfo: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        let result = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &cpuInfo, &infoCount)
        guard result == KERN_SUCCESS, let info = cpuInfo else { return [] }
        defer {
            vm_deallocate(
                mach_task_self_,
                vm_address_t(bitPattern: info),
                vm_size_t(infoCount) * vm_size_t(MemoryLayout<Int32>.size)
            )
        }
        let raw = Array(UnsafeBufferPointer(start: info, count: Int(infoCount)))
        let width = CPUTicks.statesPerCPU
        return (0..<Int(cpuCount)).map { core in
            let base = core * width
            guard base + width <= raw.count else { return CPUTicks(user: 0, system: 0, idle: 0, nice: 0) }
            return CPUTicks.summed(rawLoadInfo: Array(raw[base..<base + width]), cpuCount: 1)
        }
    }

    private func readMemory() -> MemoryUsage {
        let total = ProcessInfo.processInfo.physicalMemory
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return MemoryUsage(total: total, used: 0) }

        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)
        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0)

        let vm = VMStatistics(
            activeCount: UInt64(stats.active_count),
            inactiveCount: UInt64(stats.inactive_count),
            wireCount: UInt64(stats.wire_count),
            freeCount: UInt64(stats.free_count),
            compressorPageCount: UInt64(stats.compressor_page_count)
        )
        return MemoryUsage(physicalTotal: total, vmStats: vm, pageSize: UInt64(pageSize), swapUsed: swap.xsu_used)
    }

    /// statfs, not URLResourceValues: the latter can hang on Macs with many
    /// APFS snapshots (upstream issue #78).
    private func readDisk() -> DiskUsage {
        var fs = statfs()
        guard statfs("/", &fs) == 0 else {
            return DiskUsage.fromStatfs(blocks: 0, availableBlocks: 0, blockSize: 0)
        }
        return DiskUsage.fromStatfs(
            blocks: UInt64(fs.f_blocks),
            availableBlocks: UInt64(fs.f_bavail),
            blockSize: UInt64(fs.f_bsize)
        )
    }

    private func readNetworkBytes() -> (bytesIn: UInt64, bytesOut: UInt64) {
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0, let first = addresses else { return (0, 0) }
        defer { freeifaddrs(addresses) }
        var totalIn: UInt64 = 0
        var totalOut: UInt64 = 0
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let address = cursor {
            defer { cursor = address.pointee.ifa_next }
            let name = String(cString: address.pointee.ifa_name)
            guard name.hasPrefix("en") || name.hasPrefix("utun") || name.hasPrefix("pdp_ip") else { continue }
            guard let socketAddress = address.pointee.ifa_addr,
                  socketAddress.pointee.sa_family == UInt8(AF_LINK),
                  let data = address.pointee.ifa_data else { continue }
            let counters = data.assumingMemoryBound(to: if_data.self)
            totalIn += UInt64(counters.pointee.ifi_ibytes)
            totalOut += UInt64(counters.pointee.ifi_obytes)
        }
        return (totalIn, totalOut)
    }
}
