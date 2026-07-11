// POC 2 (player side): play a WAV to a SPECIFIC CoreAudio output device by
// UID — without touching the system default output. AVPlayer's
// audioOutputDeviceUniqueID is the verified mechanism; a bad/missing UID
// surfaces on AVPlayerItem.error (NOT player.error), so we watch the item.
//
// Usage: play_to_device <device-uid> <wav-path>

import AVFoundation
import Foundation

guard CommandLine.arguments.count == 3 else {
    print("usage: play_to_device <device-uid> <wav-path>")
    exit(2)
}
let uid = CommandLine.arguments[1]
let url = URL(fileURLWithPath: CommandLine.arguments[2])

guard FileManager.default.fileExists(atPath: url.path) else {
    print("FIXTURE_MISSING \(url.path)")
    exit(2)
}

let item = AVPlayerItem(url: url)
let player = AVPlayer(playerItem: item)
player.audioOutputDeviceUniqueID = uid

let asset = AVURLAsset(url: url)
let duration = CMTimeGetSeconds(asset.duration)
print("PLAYING uid=\(uid) duration=\(String(format: "%.2f", duration))s")
player.play()

let deadline = Date().addingTimeInterval(duration + 3.0)
while Date() < deadline {
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    if let error = item.error {
        // Device missing/invalid: no silent fallback to default output.
        print("ITEM_ERROR \(error.localizedDescription)")
        exit(1)
    }
    if CMTimeGetSeconds(player.currentTime()) >= duration - 0.05 {
        print("PLAYBACK_COMPLETE")
        exit(0)
    }
}
print("TIMEOUT currentTime=\(CMTimeGetSeconds(player.currentTime()))")
exit(1)
