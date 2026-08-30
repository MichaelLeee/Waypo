import Darwin
import Foundation

struct UtunSetupError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

/// Creates and owns a utun device via the kernel control socket.
/// Requires root. The device is destroyed when this object (and the fd) goes away.
final class UtunInterface {
    let name: String
    let fileDescriptor: Int32

    init(unit: Int32) throws {
        let fd = socket(PF_SYSTEM, SOCK_DGRAM, SYSPROTO_CONTROL)
        guard fd >= 0 else {
            throw UtunSetupError(message: "socket(PF_SYSTEM) failed: \(lastErrorText())")
        }
        self.fileDescriptor = fd

        var info = ctl_info()
        withUnsafeMutableBytes(of: &info.ctl_name) { buffer in
            _ = buffer.baseAddress.map {
                strncpy($0.assumingMemoryBound(to: CChar.self), "com.apple.net.utun_control", Int(MAX_KCTL_NAME))
            }
        }
        guard ioctl(fd, Self.ctlInfoGetInfo, &info) == 0 else {
            throw UtunSetupError(message: "CTLIOCGINFO failed: \(lastErrorText())")
        }

        var controlAddress = sockaddr_ctl()
        controlAddress.sc_len = UInt8(MemoryLayout<sockaddr_ctl>.size)
        controlAddress.sc_family = UInt8(AF_SYSTEM)
        controlAddress.ss_sysaddr = UInt16(AF_SYS_CONTROL)
        controlAddress.sc_id = info.ctl_id
        controlAddress.sc_unit = UInt32(unit + 1) // sc_unit is 1-based; 0 would let the kernel pick

        let connected = withUnsafePointer(to: &controlAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketPointer in
                connect(fd, socketPointer, socklen_t(MemoryLayout<sockaddr_ctl>.size))
            }
        }
        guard connected == 0 else {
            throw UtunSetupError(message: "utun connect failed (unit \(unit) already in use?): \(lastErrorText())")
        }

        var nameBuffer = [CChar](repeating: 0, count: Int(IFNAMSIZ))
        var nameLength: socklen_t = socklen_t(IFNAMSIZ)
        let utunOptIfName: Int32 = 2 // UTUN_OPT_IFNAME, not exposed by the Darwin module
        guard getsockopt(fd, SYSPROTO_CONTROL, utunOptIfName, &nameBuffer, &nameLength) == 0 else {
            throw UtunSetupError(message: "getsockopt(UTUN_OPT_IFNAME) failed: \(lastErrorText())")
        }
        name = String(cString: nameBuffer)
    }

    private func lastErrorText() -> String {
        String(cString: strerror(errno))
    }

    // _IOWR('N', 3, struct ctl_info); some SDK variants do not export CTLIOCGINFO
    private static let ctlInfoGetInfo: UInt = {
        let size = MemoryLayout<ctl_info>.size
        return 0xC000_0000 | (UInt(size) << 16) | (UInt(0x4E) << 8) | 3
    }()
}
