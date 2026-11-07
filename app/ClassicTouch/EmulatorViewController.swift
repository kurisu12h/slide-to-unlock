// The emulator screen: the guest screen inside the "timeline" look (EmulatorChromeView: a large year and the model at
// the top, a line of run status (uptime, CPU, memory, frames), and the Back, Home and Power buttons at the bottom).
// Touch is single-finger, in coordinates normalized to the guest screen. RootViewController decides which device runs
// and when it pauses (one device per process, see Engine.swift).
//
// Test entry points for scripts (launch arguments, passed by Xcode's Arguments, simctl launch or devicectl process
// launch; without arguments the same keys are read from Documents/autostart.json, see LaunchOptions.swift, which is
// what a launch by StikDebug uses). None of these are on when a real user boots from the list:
//   -device <id>        boot Documents/devices/<id> directly
//   -select <id>        as if the user tapped this device in the list (the full selection flow, which goes to StikDebug
//                       without JIT), see RootViewController
//   -tcg interp|jit     backend; by default JIT with a debugger, otherwise the interpreter. On a real phone, asking for
//                       JIT without a debugger falls back to the interpreter
//   -tbsize <MB>        TCG code buffer, 256 by default
//   -autounlock <s>     from this second on, press Home every 20 seconds and swipe to unlock 5 seconds later (at most
//                       8 times), 0 is off
//   -guestpng <s>       save the guest screen as PNG every few seconds (only when it changed); 5 by default for test
//                       entry points, none when booted from the list
//   -qemuargs "<...>"   extra QEMU arguments, separated by spaces (in autostart.json: "qemuargs": "<...>")
//   -resetstate YES     delete state/ before booting and start over from golden-state/ (if any) or the device itself,
//                       for cold-boot measurements
//   -waitdebugger YES   with -tcg jit: wait for a debugger to attach (up to 120 seconds) before starting QEMU
//   -autodrive YES      the app recognizes the lock and home screens itself, unlocks, idles for -idle seconds (40 by
//                       default) and exits (stage 3, see autodrive())
//   -opensettings YES   with -autodrive: after idling, open Settings, press Home to return to the home screen, then exit
//                       (step 4, see settingsTrip())
//   -swipetest YES      with -autodrive: swipe tests on the lock and home screens, recording frames and CPU per segment
//                       (M2 performance, see swipeLock(), swipeHome())
//   -perf YES           QEMU logs GL bridge, display and frame publishing times to qemu.log every second (IT_PERF=1,
//                       patches/ios-gles-perf.patch)
//   -qemuenv "A=1 B=2"  extra environment variables for QEMU (an object in autostart.json), such as IT_GLES_STRICT=0
//   -usbkbd YES         attach a USB keyboard on devices with a USB host port (off by default, see DeviceProfile.boot)
//   -jitprotocol legacy real-phone JIT uses the old brk #0x69 protocol (the default is the universal brk #0xf00d)
//   -fakejit on|off|nostik  simulator only: pretend JIT is or is not there and StikDebug is or is not installed (see JIT.swift)
// Each run's records go to Documents/logs/<time>-<device>-<backend>/: qemu.log (stderr), serial.log, stats.csv,
// events.log, argv.json, threads.csv (CPU per thread); test entry points also save guest-*.png and app-*.png. The host
// can drop command files into Documents/control/ (see pollControl).
// SPDX-License-Identifier: GPL-2.0-or-later

import UIKit

final class EmulatorViewController: UIViewController {
    private(set) var engine: Engine?
    private(set) var profile: DeviceProfile?
    /// QEMU has exited, or the boot failed
    private(set) var stopped = false
    var engineStarted: Bool { engine?.started == true }
    var onBackToList: (() -> Void)?
    var onEngineStarted: (() -> Void)?
    var onStopped: (() -> Void)?
    /// Commands in control/ that Root handles: back, resume, select (the argument is the file content)
    var onControl: ((String, String) -> Void)?

    private let deviceID: String
    private let requestedBackend: Engine.Backend?
    /// A test entry point for scripts (-device or autostart.json), not a boot the user started from the list
    private let test: Bool
    private let documents: URL
    private let defaults: LaunchOptions
    private var afterExit: (() -> Void)?

    private let screen = ScreenView()
    private let chrome = EmulatorChromeView()
    // The status line and the three buttons live in chrome; the old names are kept here
    private var status: UILabel { chrome.status }
    private var backButton: UIButton { chrome.back }
    private var homeButton: UIButton { chrome.home }
    private var powerButton: UIButton { chrome.power }

    private var displayLink: CADisplayLink?
    private var timer: Timer?
    private var serial: UInt64 = 0
    private var frames = 0
    private var guestSize = CGSize(width: 320, height: 480)
    private var lastImage: CGImage?
    private var savedSerial: UInt64 = 0
    // The guest turned its screen off (it dims by itself, or the Power button): the screen shows dark, as a real one
    // does, and a finger that comes down on it goes nowhere until it lifts (upstream's Mac app takes no input then either)
    private var screenAsleep = false
    private var touchDropped = false

    private var runDir: URL?
    private var stats: StatsLog?
    private var events: FileHandle?
    private var start: Double = 0
    private var lastGuestPNG: Double = -1000
    private var lastAppPNG: Double = -1000
    private var unlockAttempts = 0
    private var lastUnlock: Double = -1000
    private var sawBacklight = false
    private var waitedForDebugger = false
    // autodrive: the app recognizes the lock and home screens itself (GuestText), unlocks, idles and exits, with no help from the Mac
    private let ocrQueue = DispatchQueue(label: "guest-ocr", qos: .utility)
    private var ocrBusy = false
    private var lockSeenAt: Double?
    private var homeSeenAt: Double?
    private var autoUnlocks = 0
    private var lastAutoUnlock: Double = -1000
    // opensettings: after idling, tap Settings, recognize the Settings page, press Home, recognize the home screen again
    private var idleEndAt: Double?
    private var settingsIcon: CGPoint?
    private var settingsTapAt: Double?
    private var settingsTaps = 0
    private var settingsSeenAt: Double?
    private var homePressAt: Double?
    private var homePresses = 0
    private var tripDoneAt: Double?
    // swipetest: lock screen still, drag back and forth, unlock; home screen still, page flips, hold and drag back and
    // forth, still again. Each segment's start and end go into events.log (seg <name> begin|end serial= cpu=), and
    // scripts/ios/summarize-swipe.py computes frames and CPU per segment
    private var threads: ThreadLog?
    private var swipeLockAt: Double?
    private var swipeLockDoneAt: Double?
    private var swipeHomeStarted = false
    private var swipeDone = false
    private var inSegment = false
    // Before the lock screen is recognized: press Home to wake it when the screen dims (lockWakeAt), and log the recognized text every 5 seconds (lastOCRLog)
    private var maxBacklight: Int32 = 0
    private var lockWakeAt: Double = -1000
    private var lastOCRLog: Double = -1000

    init(deviceID: String, backend: Engine.Backend?, test: Bool, options: LaunchOptions, documents: URL) {
        self.deviceID = deviceID
        requestedBackend = backend
        self.test = test
        defaults = options
        self.documents = documents
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .all }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        // Add chrome first, with the guest screen on top; chrome's empty areas take no touches
        view.addSubview(chrome)

        screen.backgroundColor = UIColor(white: 0.05, alpha: 1)
        screen.layer.magnificationFilter = .linear
        screen.isHidden = true
        view.addSubview(screen)

        backButton.addAction(UIAction { [weak self] _ in
            self?.event("back_to_list")
            self?.onBackToList?()
        }, for: .touchUpInside)

        for (button, target) in [(homeButton, QemuButton.home), (powerButton, QemuButton.power)] {
            button.isHidden = true
            button.addAction(UIAction { [weak self] _ in self?.engine?.button(target, down: true) }, for: .touchDown)
            for up: UIControl.Event in [.touchUpInside, .touchUpOutside, .touchCancel] {
                button.addAction(UIAction { [weak self] _ in self?.engine?.button(target, down: false) }, for: up)
            }
        }

        screen.onTouch = { [weak self] phase, x, y in
            guard let self else { return }
            if phase == .begin { touchDropped = screenAsleep }
            if !touchDropped { engine?.touch(phase, x: x, y: y) }
        }
        boot(id: deviceID, backend: requestedBackend)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        chrome.frame = view.bounds
        chrome.layoutIfNeeded()
        screen.frame = chrome.screenFrame(for: guestSize)
    }

    /// Pauses when going back to the list or to the background (reason goes into events.log), resumes on return
    func setRunning(_ running: Bool, reason: String) {
        guard let engine, engine.started, !stopped else { return }
        engine.setRunning(running)
        displayLink?.isPaused = !running
        event(running ? "vm_resume" : "vm_pause reason=\(reason)")
    }

    /// Lets QEMU exit normally (qmp quit), then calls then; calls it right away if QEMU is not up yet
    func quitEngine(then: @escaping () -> Void) {
        guard let engine, engine.ready, !stopped else { return then() }
        afterExit = then
        engine.quit()   // a stopped VM can quit too

    }

    // MARK: Boot

    private func boot(id: String, backend requested: Engine.Backend?) {
        // JIT needs the debugger attached before QEMU allocates its code region (region.c asks it with brk #0x69 to prepare the region right then).
        // Attaching with devicectl --start-stopped leaves a pending SIGSTOP, so the app starts normally and waits here instead.
        if requested == .jit, defaults.bool(forKey: "waitdebugger"), !debuggerAttached(), !waitedForDebugger {
            // Load the JIT library before waiting for the debugger: dlopening the 34 MB library after attaching makes LLDB
            // handle dyld's load notifications internally, and colliding with the debugger script's "continue" hangs on
            // "Resume timed out" (about half the attaches in stage 2 failed this way).
            Engine.preload(.jit)
            let deadline = ProcessInfo.processInfo.systemUptime + 120
            status.text = String(localized: "JIT: waiting for the debugger to attach (up to 120 s)…")
            Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] t in
                guard let self else { return t.invalidate() }
                if debuggerAttached() || ProcessInfo.processInfo.systemUptime > deadline {
                    t.invalidate()
                    self.waitedForDebugger = true
                    self.boot(id: id, backend: requested)
                }
            }
            return
        }
        start = ProcessInfo.processInfo.systemUptime
        do {
            let profile = try DeviceProfile(base: documents.appendingPathComponent("devices/\(id)", isDirectory: true))
            self.profile = profile
            guestSize = CGSize(width: profile.info.width, height: profile.info.height)
            var backend = requested ?? (debuggerAttached() ? .jit : .interp)
            var note = ""
            #if !targetEnvironment(simulator)
            if backend == .jit && !debuggerAttached() {
                backend = .interp
                note = " (no debugger, JIT fell back to the interpreter)"
            }
            #endif
            chrome.configure(profile, backend: backend == .jit ? "JIT" : String(localized: "Interpreter"))

            let stamp = DateFormatter()
            stamp.dateFormat = "yyyyMMdd-HHmmss"
            let run = "\(stamp.string(from: Date()))-\(id)-\(backend.rawValue)"
            let dir = documents.appendingPathComponent("logs/\(run)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            runDir = dir
            // QEMU prints its errors to stderr/stdout; when the boot fails it exits right away, and this file is all that is left.
            freopen(dir.appendingPathComponent("qemu.log").path, "a", stderr)
            freopen(dir.appendingPathComponent("qemu.log").path, "a", stdout)
            setvbuf(stderr, nil, _IONBF, 0)
            setvbuf(stdout, nil, _IOLBF, 0)
            FileManager.default.createFile(atPath: dir.appendingPathComponent("events.log").path, contents: nil)
            events = try FileHandle(forWritingTo: dir.appendingPathComponent("events.log"))
            stats = StatsLog(url: dir.appendingPathComponent("stats.csv"))
            threads = ThreadLog(url: dir.appendingPathComponent("threads.csv"))

            if defaults.bool(forKey: "resetstate") { try profile.resetState() }
            try profile.prepareState()
            let bootrom = try placeholderBootrom(in: documents)
            // Not UserDefaults: it treats values starting with "-" (such as "-qmp tcp:…") as the next key, so take the item right after -qemuargs
            let launch = ProcessInfo.processInfo.arguments
            let raw = launch.firstIndex(of: "-qemuargs").flatMap { $0 + 1 < launch.count ? launch[$0 + 1] : nil }
                ?? defaults.string(forKey: "qemuargs")
            let extra = (raw ?? "").split(separator: " ").map(String.init)
            let tb = defaults.integer(forKey: "tbsize")
            let usbKeyboard = defaults.bool(forKey: "usbkbd")
            var (argv, env) = try profile.boot(backend: backend, bootrom: bootrom, logs: dir, run: "0",
                                               tbSize: tb > 0 ? tb : 256, usbKeyboard: usbKeyboard, extra: extra)
            // tcg/region.c (patches/ios-txm-jit-protocol.patch): legacy uses the old brk #0x69
            if let jitProtocol = defaults.string(forKey: "jitprotocol") { env["QEMU_IOS_JIT_PROTOCOL"] = jitProtocol }
            if defaults.bool(forKey: "perf") { env["IT_PERF"] = "1" }
            env.merge(defaults.environment(forKey: "qemuenv")) { _, new in new }
            try JSONSerialization.data(withJSONObject: ["argv": argv, "env": env], options: .prettyPrinted)
                .write(to: dir.appendingPathComponent("argv.json"))

            let engine = try Engine(backend: backend)
            self.engine = engine
            engine.onExit = { [weak self] code in
                guard let self else { return }
                self.event("qemu_exit status=\(code)")
                self.stopped = true
                self.displayLink?.isPaused = true
                self.status.text = String(format: String(localized: "Shut down (%d); log in logs/%@/qemu.log"), code, run)
                self.onStopped?()
                self.afterExit?()
                self.afterExit = nil
            }
            start = ProcessInfo.processInfo.systemUptime
            // QEMU's [perf] lines record seconds since boot (CLOCK_UPTIME_RAW); subtract this to get this file's times
            event(String(format: "clock up0=%.3f", start))
            let source = test ? (defaults.fromFile ? "autostart.json" : "arguments") : "list"
            event("boot config=\(source) device=\(id) board=\(profile.board) version=\(profile.productVersion) backend=\(backend.rawValue) "
                  + "build=\(engine.buildID) debugger=\(debuggerAttached()) bootrom=\(bootrom.lastPathComponent) "
                  + "usbkbd=\(profile.info.hasUSBHost && usbKeyboard)\(note)")
            #if targetEnvironment(simulator)
            engine.start(argv: argv, environment: env)
            onEngineStarted?()
            #else
            if backend == .jit {
                // QEMU asks the debugger to prepare the code region as soon as it starts, and meanwhile the debugger stops
                // the whole app and the screen freezes (under a second with StikDebug). Draw this line before starting QEMU.
                status.text = String(localized: "JIT: StikDebug is preparing the code region; the screen will pause briefly")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    engine.start(argv: argv, environment: env)
                    self?.onEngineStarted?()
                }
            } else {
                engine.start(argv: argv, environment: env)
                onEngineStarted?()
            }
            #endif

            screen.isHidden = false
            homeButton.isHidden = false
            powerButton.isHidden = false
            let link = CADisplayLink(target: self, selector: #selector(tick))
            link.add(to: .main, forMode: .common)
            displayLink = link
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.everySecond() }
            view.setNeedsLayout()
        } catch {
            status.text = String(format: String(localized: "Boot failed: %@"), "\(error)")
            event("boot_failed \(error.logText)")
            stopped = true
            onStopped?()
        }
    }

    func event(_ text: String) {
        let line = String(format: "%.1f %@\n", ProcessInfo.processInfo.systemUptime - start, text)
        events?.write(Data(line.utf8))
    }

    // MARK: Screen

    @objc private func tick() {
        guard let engine, engine.started else { return }
        let asleep = engine.ready && engine.displaySleeping
        if asleep != screenAsleep {
            screenAsleep = asleep
            event(asleep ? "display_sleep" : "display_wake")
            screen.layer.contents = asleep ? nil : lastImage
        }
        guard let f = engine.frame(after: &serial) else { return }
        let bytesPerRow = f.width * 4
        let data = Data(bytes: f.pixels, count: bytesPerRow * f.height)
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(width: f.width, height: f.height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue
                                                           | CGImageAlphaInfo.noneSkipFirst.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return }
        if frames == 0 { event("first_frame \(f.width)x\(f.height)") }
        frames += 1
        lastImage = image
        if CGSize(width: f.width, height: f.height) != guestSize {
            guestSize = CGSize(width: f.width, height: f.height)
            view.setNeedsLayout()
        }
        if !asleep { screen.layer.contents = image }
    }

    private func everySecond() {
        guard let engine, let stats else { return }
        let sample = ProcessSample.now(since: start)
        let backlight = engine.ready ? engine.backlightLevel : -1
        let pct = stats.append(sample, serial: serial, backlight: backlight)
        threads?.append(wall: sample.wall)
        if backlight > 0 && !sawBacklight {
            sawBacklight = true
            event("backlight_on level=\(backlight)")
        }
        let minutes = Int(sample.wall) / 60, seconds = Int(sample.wall) % 60
        if !stopped {
            status.text = String(
                format: String(localized: "%@ · %@ · %d:%02d\nCPU %.0f%% (%.0f s total) · using %.0f MB · %.0f MB free · frame %d"),
                profile?.displayName ?? "", engine.backend == .jit ? "JIT" : String(localized: "Interpreter (slow)"), minutes, seconds,
                pct, sample.cpuSeconds, Double(sample.footprint) / 1_048_576, Double(sample.available) / 1_048_576, frames)
        }

        // Saved images are only for scripts: test entry points save a guest screen every 5 seconds and a window screenshot every 15 seconds by default; booting from the list saves none (unless -guestpng is given)
        let given = defaults.double(forKey: "guestpng")
        let every = given > 0 ? given : (test ? 5 : 0)
        if every > 0, !inSegment, let image = lastImage, serial != savedSerial, sample.wall - lastGuestPNG >= every {
            savedSerial = serial
            lastGuestPNG = sample.wall
            save(UIImage(cgImage: image), name: String(format: "guest-%04d.png", Int(sample.wall)))
        }
        if test, !inSegment, sample.wall - lastAppPNG >= 15, let window = view.window {
            lastAppPNG = sample.wall
            let shot = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
            }
            save(shot, name: String(format: "app-%04d.png", Int(sample.wall)))
        }

        let unlockFrom = defaults.double(forKey: "autounlock")
        if unlockFrom > 0, sample.wall >= unlockFrom, unlockAttempts < 8, sample.wall - lastUnlock >= 20, engine.ready {
            unlockAttempts += 1
            lastUnlock = sample.wall
            event("unlock_attempt \(unlockAttempts)")
            unlock(engine)
        }
        pollControl(engine)
        if defaults.bool(forKey: "autodrive") { autodrive(engine, at: sample.wall) }
    }

    /// The lock screen turns off after a few untouched seconds, and swipes do nothing while it is off: press Home first to
    /// wake it, and wait for the interpreter to light the screen before swiping.
    /// Recognizes the guest screen once a second: on the lock screen it unlocks (unlock presses Home first to wake a dark
    /// screen), retrying every 12 seconds; once the home screen is recognized, recognition stops, and after idling for
    /// idle seconds (40 by default) QEMU is told to exit (with opensettings, settingsTrip runs first).
    /// The times of lock_seen and home_seen are the boot measurements for the lock and home screens.
    private func autodrive(_ engine: Engine, at now: Double) {
        let swipe = defaults.bool(forKey: "swipetest")
        if let home = homeSeenAt {
            if swipe && !swipeHomeStarted {
                swipeHomeStarted = true
                swipeHome(engine)
            }
            let idle = defaults.double(forKey: "idle")
            guard now - home >= (idle > 0 ? idle : 40), engine.ready, !swipe || swipeDone else { return }
            if defaults.bool(forKey: "opensettings"), tripDoneAt == nil {
                settingsTrip(engine, at: now)
            } else if now - (tripDoneAt ?? 0) >= 5 {
                event("auto_quit")
                engine.quit()
            }
            return
        }
        if swipe, lockSeenAt != nil, swipeLockAt == nil {
            swipeLockAt = now
            swipeLock(engine)
        }
        // The swipe test's lock segment unlocks by itself; normal retries resume only if the home screen has not come 12 seconds after it ends
        let swipeHolds = swipe && lockSeenAt != nil && (swipeLockDoneAt.map { now - $0 < 12 } ?? true)
        if !swipeHolds, let lock = lockSeenAt, now - lastAutoUnlock >= 12, now - lock < 300, autoUnlocks < 12 {
            autoUnlocks += 1
            lastAutoUnlock = now
            event("auto_unlock \(autoUnlocks)")
            unlock(engine)
        }
        // If the lit lock screen is never recognized, it dims by itself and stops animating: press Home to wake it and try again (Home does nothing while it is lit)
        let backlight = engine.backlightLevel
        maxBacklight = max(maxBacklight, backlight)
        if lockSeenAt == nil, maxBacklight > 0, backlight > 0, backlight * 2 < maxBacklight, now - lockWakeAt >= 15 {
            lockWakeAt = now
            event("lock_wake backlight=\(backlight)")
            pressHome(engine)
        }
        // No text recognition during the lock segment measurement (it counts toward this process's CPU too)
        guard !ocrBusy, !(swipe && lockSeenAt != nil && swipeLockDoneAt == nil), let image = lastImage else { return }
        ocrBusy = true
        ocrQueue.async { [weak self] in
            let texts = GuestText.recognize(image).texts
            DispatchQueue.main.async {
                guard let self else { return }
                self.ocrBusy = false
                let t = ProcessInfo.processInfo.systemUptime - self.start
                if self.lockSeenAt == nil, self.sawBacklight, t - self.lastOCRLog >= 5 {
                    self.lastOCRLog = t
                    self.event("ocr " + texts.prefix(6).joined(separator: " | "))
                }
                if self.lockSeenAt == nil, GuestText.isLockScreen(texts) {
                    self.lockSeenAt = t
                    self.event(String(format: "lock_seen %.1f", t))
                    self.lastAutoUnlock = -1000  // unlock right away, before the screen goes dark and into deep sleep
                } else if self.homeSeenAt == nil, GuestText.isHomeScreen(texts),
                          self.lockSeenAt != nil || GuestText.homeMarkCount(texts) >= 3 {
                    // 1.0 cold-booting from the golden state and the iPod's 2.x booting for the first time after activation skip the lock screen (no lock_seen)
                    self.homeSeenAt = t
                    self.event(String(format: "home_seen %.1f", t))
                }
            }
        }
    }

    /// Segment markers for the swipe test: events.log records "seg <name> begin|end serial=<frame serial> cpu=<this process's CPU seconds>".
    private func segment(_ name: String, _ edge: String) {
        inSegment = edge == "begin"
        let cpu = ProcessSample.now(since: start).cpuSeconds
        event(String(format: "seg %@ %@ serial=%llu cpu=%.2f", name, edge, serial, cpu))
    }

    /// A list of actions ordered by start time (seconds from now)
    private func schedule(_ steps: [(Double, () -> Void)]) {
        for (at, step) in steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + at) { [weak self] in
                guard let self, !self.stopped else { return }
                step()
            }
        }
    }

    /// The swipe test's lock segment (starts right after the lock screen is recognized): press Home first (the lock screen
    /// dims and stops animating after a few untouched seconds, and recognition may be a few seconds late, so a press keeps
    /// it lit; Home does nothing while it is lit). 1.5 seconds later, three times: hold at the bottom of the lock screen,
    /// drag right to 0.55 and back, release (1.6 seconds each, no unlock; on iOS 7 the whole lock screen follows the finger,
    /// on 3.x and 6.x it is a slider). Then stay still for 4 seconds (iOS 7's "slide to unlock" shimmer is a continuous
    /// animation), then slowly swipe to unlock. No text recognition meanwhile.
    private func swipeLock(_ engine: Engine) {
        let y = 0.9
        var steps: [(Double, () -> Void)] = [(0, { self.pressHome(engine) }),
                                              (1.5, { self.segment("lock_drag", "begin") })]
        for i in 0..<3 {
            steps.append((1.6 + 2.0 * Double(i), {
                engine.drag(path: [(0.15, y), (0.55, y), (0.15, y)], milliseconds: 1600)
            }))
        }
        // The 3.x and 6.x lock screens go dark after a few untouched seconds, and an iPod touch 2nd gen that stays dark for long enters deep sleep (no wake with the placeholder SecureROM), so small-screen devices stay still for only 2.5 seconds
        let still = guestSize.width < 640 ? 2.5 : 4.0
        steps.append((7.8, { self.segment("lock_drag", "end"); self.segment("lock_static", "begin") }))
        steps.append((7.8 + still, { self.segment("lock_static", "end") }))
        steps.append((8.0 + still, {
            self.event("swipe_unlock")
            engine.drag(path: [(0.12, y), (0.95, y)], milliseconds: 700)
        }))
        steps.append((9.0 + still, { self.swipeLockDoneAt = ProcessInfo.processInfo.systemUptime - self.start }))
        schedule(steps)
    }

    /// The swipe test's home segment (after the home screen is recognized): 3 seconds later, still for 6 seconds; 6 page
    /// flips (alternating left and right, 0.25 seconds each, 1.5 seconds apart); hold and drag between 0.3 and 0.7 for 4
    /// seconds (M0's drag measurement); release, and 1 second later stay still for 10 seconds. Then idle and exit as usual.
    private func swipeHome(_ engine: Engine) {
        let y = 0.45
        var steps: [(Double, () -> Void)] = [(3, { self.segment("home_static", "begin") }),
                                              (9, { self.segment("home_static", "end"); self.segment("home_swipe", "begin") })]
        for i in 0..<6 {
            let path = i % 2 == 0 ? [(0.8, y), (0.2, y)] : [(0.2, y), (0.8, y)]
            // Frames of the page flip animation itself: from finger down to 0.6 seconds later (between flips the screen is still, which would pull down the average of the whole segment)
            steps.append((9.2 + 1.5 * Double(i), {
                self.event(String(format: "flip %d begin serial=%llu", i, self.serial))
                engine.drag(path: path, milliseconds: 250)
            }))
            steps.append((9.8 + 1.5 * Double(i), { self.event(String(format: "flip %d end serial=%llu", i, self.serial)) }))
        }
        steps.append((18.5, { self.segment("home_swipe", "end"); self.segment("home_drag", "begin") }))
        steps.append((18.6, {
            engine.drag(path: [(0.5, y), (0.7, y), (0.3, y), (0.7, y), (0.3, y), (0.5, y)], milliseconds: 4000)
        }))
        steps.append((22.7, { self.segment("home_drag", "end") }))
        steps.append((24, { self.segment("home_static2", "begin") }))
        steps.append((34, { self.segment("home_static2", "end"); self.swipeDone = true }))
        schedule(steps)
    }

    /// Step 4: confirms touch and the Home button work in the guest. The idle segment ends here (idle_end; the idle CPU in
    /// scripts/ios/summarize-run.py is cut off here). When "Settings" is recognized on the home screen, tap the icon above
    /// it (as M0's bench.py does); once the Settings page is recognized, save that guest screen (settings-*.png), press Home
    /// 2 seconds later, save another once the home screen is back (home-back-*.png), and exit 5 seconds later.
    /// Tapping the icon and pressing Home are each retried after 20 seconds without response, at most 3 times each; if the
    /// whole trip takes over 150 seconds, settings_trip_timeout is logged and the app exits as usual.
    private func settingsTrip(_ engine: Engine, at now: Double) {
        if idleEndAt == nil {
            idleEndAt = now
            event("idle_end")
        }
        if let begun = idleEndAt, now - begun > 150 {
            event("settings_trip_timeout")
            tripDoneAt = now
            return
        }
        if settingsSeenAt == nil {
            if let icon = settingsIcon, settingsTaps < 3, now - (settingsTapAt ?? -1000) >= 20 {
                settingsTaps += 1
                settingsTapAt = now
                // 0.06 above the label's center: about 58 pixels on iPhone 4 and about 29 on 320x480 devices, inside the icon either way
                let x = Double(icon.x), y = Double(icon.y) - 0.06
                event(String(format: "tap_settings %d at %.3f,%.3f", settingsTaps, x, y))
                engine.touch(.begin, x: x, y: y)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { engine.touch(.end, x: x, y: y) }
            }
        } else if let seen = settingsSeenAt, now - seen >= 2, homePresses < 3, now - (homePressAt ?? -1000) >= 20 {
            homePresses += 1
            homePressAt = now
            event("home_press \(homePresses)")
            pressHome(engine)
        }
        guard !ocrBusy, let image = lastImage else { return }
        ocrBusy = true
        ocrQueue.async { [weak self] in
            let reading = GuestText.recognize(image, locate: ["Settings"])
            DispatchQueue.main.async {
                guard let self else { return }
                self.ocrBusy = false
                let t = ProcessInfo.processInfo.systemUptime - self.start
                if self.settingsSeenAt == nil {
                    if GuestText.isSettingsScreen(reading.texts) {
                        self.settingsSeenAt = t
                        self.event(String(format: "settings_seen %.1f", t))
                        self.save(UIImage(cgImage: image), name: String(format: "settings-%04d.png", Int(t)))
                    } else if self.settingsIcon == nil, GuestText.isHomeScreen(reading.texts),
                              let icon = reading.places["Settings"] {
                        self.settingsIcon = icon
                        self.event(String(format: "settings_label %.3f,%.3f", icon.x, icon.y))
                    }
                } else if self.homePressAt != nil, self.tripDoneAt == nil, GuestText.isHomeScreen(reading.texts) {
                    self.tripDoneAt = t
                    self.event(String(format: "home_back %.1f", t))
                    self.save(UIImage(cgImage: image), name: String(format: "home-back-%04d.png", Int(t)))
                }
            }
        }
    }

    /// Presses Home to wake the screen, then swipes to unlock. iOS 10 opens on the Home press itself (no slider; a swipe
    /// after it would page the home screen to Today). On iOS 7 to 9 the whole lock screen follows the finger, so the
    /// swipe crosses its lower middle (along the "slide to unlock" line it often stuck halfway). They ignore touches for
    /// a while after waking (about 2 seconds on a Mac, from under 3 to over 5 on a phone) and go dark again 7 to 10
    /// seconds after waking whatever the finger does; on a phone the lock screen also trails the finger by over a
    /// second, and a swipe still being played out when the screen goes dark leaves it stuck halfway. A second Home
    /// press on the lit lock screen restarts that timer. So: Home, Home again 5 seconds later, and the swipe a second
    /// after that, taking a second, with the finger kept at the end for another second before lifting so that the lock
    /// screen has caught up and settles on the unlocked side (docs/reports/touch-calibration.md). iPhone OS 1 to 6 need
    /// the slider at the bottom.
    private func unlock(_ engine: Engine) {
        pressHome(engine)
        let major = profile?.majorVersion ?? 0
        if major >= 10 { return }
        guard major >= 7 else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { engine.drag(from: (0.18, 0.9), to: (0.92, 0.9)) }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, !self.stopped, self.homeSeenAt == nil else { return }
            self.pressHome(engine)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            guard let self, !self.stopped, self.homeSeenAt == nil else { return }
            self.event("unlock_swipe")
            engine.drag(from: (0.18, 0.7), to: (0.92, 0.7), milliseconds: 1000, steps: 40, holdMilliseconds: 1000)
        }
    }

    private func pressHome(_ engine: Engine) {
        engine.button(.home, down: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { engine.button(.home, down: false) }
    }

    /// The host's control channel (scripts/ios/sim-boot.sh, device-boot.sh): drop a file into Documents/control/, and the
    /// file name is the command. unlock: press Home and swipe to unlock; home: press Home once; quit: let QEMU exit
    /// normally; tap: the file content is "x,y" in normalized guest screen coordinates (origin at top left), tapped there
    /// (held 0.3 seconds, as tools/a5/qinput.py does), for scripts with no tap tool; back: return to the list; resume:
    /// go from the list back to the screen; select: as if the user tapped the device named in the file in the list
    /// (switches systems with no confirmation).
    private func pollControl(_ engine: Engine) {
        let dir = documents.appendingPathComponent("control", isDirectory: true)
        for command in ["unlock", "home", "quit", "tap", "back", "resume", "select"] {
            let file = dir.appendingPathComponent(command)
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            let argument = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            try? FileManager.default.removeItem(at: file)
            event("control \(command)")
            switch command {
            case "unlock": unlock(engine)
            case "home": pressHome(engine)
            case "quit": engine.quit()
            case "tap":
                let xy = argument.split(whereSeparator: { ", \n".contains($0) }).compactMap { Double($0) }
                guard xy.count >= 2 else { break }
                event(String(format: "tap %.3f,%.3f", xy[0], xy[1]))
                engine.touch(.begin, x: xy[0], y: xy[1])
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { engine.touch(.end, x: xy[0], y: xy[1]) }
            // Scripts write different content each time (devicectl skips files that have not changed); select takes the first word
            default: onControl?(command, String(argument.split(separator: " ").first ?? ""))
            }
        }
    }

    private func save(_ image: UIImage, name: String) {
        guard let dir = runDir, let png = image.pngData() else { return }
        try? png.write(to: dir.appendingPathComponent(name))
    }
}

/// The guest screen: single-finger touches converted to normalized coordinates.
final class ScreenView: UIView {
    var onTouch: ((TouchPhase, Double, Double) -> Void)?
    private weak var tracked: UITouch?

    private func send(_ phase: TouchPhase, _ touch: UITouch) {
        let p = touch.location(in: self)
        onTouch?(phase, Double(p.x / bounds.width), Double(p.y / bounds.height))
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard tracked == nil, let t = touches.first else { return }
        tracked = t
        send(.begin, t)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let t = tracked, touches.contains(t) { send(.update, t) }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let t = tracked, touches.contains(t) {
            send(.end, t)
            tracked = nil
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { touchesEnded(touches, with: event) }
}
