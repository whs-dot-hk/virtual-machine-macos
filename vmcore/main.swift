// The smallest Virtualization.framework boot.
// Usage: vmcore <disk.img> <uefi-dir> <cpus> <memory-mb>
// Boots the guest disk with UEFI firmware (VZEFIBootLoader), not a direct kernel.
// A GUI window is required: the framework has no serial console on this path.

import Cocoa
import Virtualization

let args = CommandLine.arguments
guard args.count == 5 else {
    fputs("usage: vmcore <disk.img> <uefi-dir> <cpus> <memory-mb>\n", stderr)
    exit(1)
}

let diskURL = URL(fileURLWithPath: args[1])
let uefiURL = URL(fileURLWithPath: args[2], isDirectory: true)
let cpus = Int(args[3]) ?? 2
let memBytes = (UInt64(args[4]) ?? 2048) * 1024 * 1024

try FileManager.default.createDirectory(at: uefiURL, withIntermediateDirectories: true)

let config = VZVirtualMachineConfiguration()
config.cpuCount = max(cpus, VZVirtualMachineConfiguration.minimumAllowedCPUCount)
config.memorySize = max(memBytes, VZVirtualMachineConfiguration.minimumAllowedMemorySize)

let disk = try VZDiskImageStorageDeviceAttachment(url: diskURL, readOnly: false)
config.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: disk)]

let net = VZVirtioNetworkDeviceConfiguration()
net.attachment = VZNATNetworkDeviceAttachment()
config.networkDevices = [net]
config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]

// UEFI firmware. The guest disk (Debian nocloud) supplies its own EFI boot entry.
let boot = VZEFIBootLoader()
boot.variableStore = try VZEFIVariableStore(creatingVariableStoreAt: uefiURL.appendingPathComponent("vars"))
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
