// The smallest Virtualization.framework boot.
// Usage: vmcore <disk.img> <efi-dir> <cpus> <memory-mb>
// A GUI window is required: the framework has no serial console on this path.

import Cocoa
import Virtualization

let args = CommandLine.arguments
guard args.count == 5 else {
    fputs("usage: vmcore <disk.img> <efi-dir> <cpus> <memory-mb>\n", stderr)
    exit(1)
}

let diskURL = URL(fileURLWithPath: args[1])
let efiURL = URL(fileURLWithPath: args[2], isDirectory: true)
let cpus = Int(args[3]) ?? 2
let memBytes = (UInt64(args[4]) ?? 2048) * 1024 * 1024

try FileManager.default.createDirectory(at: efiURL, withIntermediateDirectories: true)

let config = VZVirtualMachineConfiguration()
config.cpuCount = max(cpus, VZVirtualMachineConfiguration.minimumAllowedCPUCount)
config.memorySize = max(memBytes, VZVirtualMachineConfiguration.minimumAllowedMemorySize)

let disk = try VZDiskImageStorageDeviceAttachment(url: diskURL, readOnly: false)
config.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: disk)]

let net = VZVirtioNetworkDeviceConfiguration()
net.attachment = VZNATNetworkDeviceAttachment()
config.networkDevices = [net]
config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]

let boot = VZEFIBootLoader()
boot.variableStore = try VZEFIVariableStore(creatingVariableStoreAt: efiURL.appendingPathComponent("vars"))
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

class App: NSApplication, NSApplicationDelegate, NSWindowDelegate {
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
        vm.start { err in
            if let err = err {
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

let app = App.shared
app.setActivationPolicy(.regular)
app.delegate = app as App
app.activate(ignoringOtherApps: true)
app.run()
