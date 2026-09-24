// The smallest Virtualization.framework boot.
// Usage: vmcore <disk.img> <NVRAM> <cpus> <memory-mb> [cidata.raw]
// Boots the guest disk with VZEFIBootLoader, not a direct kernel.
// Optional last arg is a NoCloud seed disk (FAT, label cidata). Cloud-init
// reads it once. A GUI window is required: no serial console on this path.

import Cocoa
import Virtualization

let args = CommandLine.arguments
guard args.count == 5 || args.count == 6 else {
    fputs("usage: vmcore <disk.img> <NVRAM> <cpus> <memory-mb> [cidata.raw]\n", stderr)
    exit(1)
}

let diskURL = URL(fileURLWithPath: args[1])
let nvramURL = URL(fileURLWithPath: args[2])
let cpus = Int(args[3]) ?? 2
let memBytes = (UInt64(args[4]) ?? 2048) * 1024 * 1024
let seedURL = args.count == 6 ? URL(fileURLWithPath: args[5]) : nil

try FileManager.default.createDirectory(at: nvramURL.deletingLastPathComponent(), withIntermediateDirectories: true)

let config = VZVirtualMachineConfiguration()
config.cpuCount = max(cpus, VZVirtualMachineConfiguration.minimumAllowedCPUCount)
config.memorySize = max(memBytes, VZVirtualMachineConfiguration.minimumAllowedMemorySize)

let disk = try VZDiskImageStorageDeviceAttachment(url: diskURL, readOnly: false)
var storage = [VZVirtioBlockDeviceConfiguration(attachment: disk)]
if let seedURL {
    let seed = try VZDiskImageStorageDeviceAttachment(url: seedURL, readOnly: true)
    storage.append(VZVirtioBlockDeviceConfiguration(attachment: seed))
}
config.storageDevices = storage

let net = VZVirtioNetworkDeviceConfiguration()
net.attachment = VZNATNetworkDeviceAttachment()
config.networkDevices = [net]
config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]

// Apple's GUI Linux sample stores the EFI variable store in a file named NVRAM
// and boots with VZEFIBootLoader. The guest disk supplies the boot entry.
let boot = VZEFIBootLoader()
boot.variableStore = try VZEFIVariableStore(creatingVariableStoreAt: nvramURL)
config.bootLoader = boot

let gui = VZVirtioGraphicsDeviceConfiguration()
gui.scanouts = [VZVirtioGraphicsScanoutConfiguration(widthInPixels: 1280, heightInPixels: 800)]
config.graphicsDevices = [gui]
config.keyboards = [VZUSBKeyboardConfiguration()]
config.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]

try config.validate()

let vm = VZVirtualMachine(configuration: config)
let delegate = VMDelegate()
vm.delegate = delegate

class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: NSWindow!
    func applicationDidFinishLaunching(_ note: Notification) {
        let view = VZVirtualMachineView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800))
        view.virtualMachine = vm
        window = NSWindow(
            contentRect: view.frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "debian"
        window.contentView = view
        window.delegate = self
        window.makeKeyAndOrderFront(nil)
        vm.start { result in
            if case .failure(let err) = result {
                fputs("start failed: \(err.localizedDescription)\n", stderr)
                exit(1)
            }
            fputs("guest started\n", stderr)
        }
    }
    func windowWillClose(_ note: Notification) {
        exit(0)
    }
}

class VMDelegate: NSObject, VZVirtualMachineDelegate {
    func guestDidStop(_ vm: VZVirtualMachine) {
        fputs("guest stopped\n", stderr)
        exit(0)
    }
    func virtualMachine(_ vm: VZVirtualMachine, didStopWithError err: Error) {
        fputs("guest error: \(err.localizedDescription)\n", stderr)
        exit(1)
    }
}

let app = NSApplication.shared
let appDelegate = AppDelegate()
app.setActivationPolicy(.regular)
app.delegate = appDelegate
app.activate(ignoringOtherApps: true)
app.run()
