// Which processes are recording from a microphone right now (CoreAudio, macOS 14+).
//   mic-users                  pid <tab> bundle id <tab> path, one line per process
//   mic-users --watch <prefix> prints 1/0 whenever a process whose bundle id starts
//                              with <prefix> starts/stops recording (polls every 100 ms)
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

let args = CommandLine.arguments
if args.count >= 3 && args[1] == "--watch" {
  let prefix = args[2]
  setvbuf(stdout, nil, _IOLBF, 0)
  var last: Bool? = nil
  while true {
    let on = recording().contains { bundleID($0).hasPrefix(prefix) }
    if on != last { print(on ? "1" : "0"); last = on }
    // Exit when Hammerspoon goes away (we get reparented to launchd).
    if getppid() == 1 { exit(0) }
    usleep(100_000)
  }
} else {
  for id in recording() {
    let pid: pid_t = value(id, kAudioProcessPropertyPID, pid_t(0))
    var buf = [CChar](repeating: 0, count: 4096)
    proc_pidpath(pid, &buf, UInt32(buf.count))
    print("\(pid)\t\(bundleID(id))\t\(String(cString: buf))")
  }
}
