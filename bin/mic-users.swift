// Which processes are recording from a microphone right now (CoreAudio, macOS 14+).
//   mic-users                  pid <tab> bundle id <tab> path, one line per process
//   mic-users --watch <prefix> prints 1/0 whenever a process whose bundle id starts
//                              with <prefix> starts/stops recording
//   mic-users --follow         prints the full list (as above) followed by a "." line every
//                              time it changes; one long-lived reader instead of a process per poll
// Both long-lived modes are event-driven (Core Audio property listeners, no polling) and exit
// when the parent dies. Why (2026-11-09): every new process that talks to Core Audio registers
// as a client in coreaudiod, and running this once a second cost coreaudiod ~25% of a core.
// Built: swiftc -O bin/mic-users.swift -o bin/mic-users
import CoreAudio
import Darwin
import Foundation

func address(_ sel: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
  AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
}

func value<T: BinaryInteger>(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector, _ def: T) -> T {
  var addr = address(sel)
  var v = def
  var size = UInt32(MemoryLayout<T>.size)
  _ = AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &v)
  return v
}

func bundleID(_ obj: AudioObjectID) -> String {
  var addr = address(kAudioProcessPropertyBundleID)
  var cf: Unmanaged<CFString>? = nil
  var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
  guard AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &cf) == noErr, let s = cf else { return "" }
  return s.takeRetainedValue() as String
}

func recording() -> [AudioObjectID] {
  let sys = AudioObjectID(kAudioObjectSystemObject)
  var addr = address(kAudioHardwarePropertyProcessObjectList)
  var size: UInt32 = 0
  guard AudioObjectGetPropertyDataSize(sys, &addr, 0, nil, &size) == noErr else { return [] }
  var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
  guard AudioObjectGetPropertyData(sys, &addr, 0, nil, &size, &ids) == noErr else { return [] }
  return ids.filter { value($0, kAudioProcessPropertyIsRunningInput, UInt32(0)) != 0 }
}

func lines() -> [String] {
  recording().map { id in
    let pid: pid_t = value(id, kAudioProcessPropertyPID, pid_t(0))
    var buf = [CChar](repeating: 0, count: 4096)
    proc_pidpath(pid, &buf, UInt32(buf.count))
    return "\(pid)\t\(bundleID(id))\t\(String(cString: buf))"
  }
}

// Calls onChange (on `queue`) whenever any process starts/stops recording or processes come and go.
func follow(_ onChange: @escaping () -> Void) -> Never {
  let queue = DispatchQueue(label: "mic-users")
  let sys = AudioObjectID(kAudioObjectSystemObject)
  var watched = Set<AudioObjectID>()
  func watchAll() {
    var addr = address(kAudioHardwarePropertyProcessObjectList)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(sys, &addr, 0, nil, &size) == noErr else { return }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(sys, &addr, 0, nil, &size, &ids) == noErr else { return }
    for id in ids where !watched.contains(id) {
      watched.insert(id)
      var a = address(kAudioProcessPropertyIsRunningInput)
      AudioObjectAddPropertyListenerBlock(id, &a, queue) { _, _ in onChange() }
    }
    watched.formIntersection(ids)
  }
  var listAddr = address(kAudioHardwarePropertyProcessObjectList)
  AudioObjectAddPropertyListenerBlock(sys, &listAddr, queue) { _, _ in watchAll(); onChange() }
  queue.sync { watchAll(); onChange() }
  // Exit when the parent goes away (we get reparented to launchd); a slow safety re-check too.
  let t = DispatchSource.makeTimerSource(queue: queue)
  t.schedule(deadline: .now() + 5, repeating: 5)
  t.setEventHandler { if getppid() == 1 { exit(0) }; onChange() }
  t.resume()
  dispatchMain()
}

let args = CommandLine.arguments
setvbuf(stdout, nil, _IOLBF, 0)
if args.count >= 3 && args[1] == "--watch" {
  let prefix = args[2]
  var last: Bool? = nil
  follow {
    let on = recording().contains { bundleID($0).hasPrefix(prefix) }
    if on != last { print(on ? "1" : "0"); last = on }
  }
} else if args.count >= 2 && args[1] == "--follow" {
  var last: [String]? = nil
  follow {
    let now = lines()
    if now != last { for l in now { print(l) }; print("."); last = now }
  }
} else {
  for l in lines() { print(l) }
}
