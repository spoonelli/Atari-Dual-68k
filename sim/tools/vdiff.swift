// vdiff.swift -- per-frame change series for a video capture.
//
// Reads every frame of a video in order (AVAssetReader, no re-seeking, so the
// frame indices really are consecutive), crops to the game area, blanks any
// rectangles given as masks (our on-screen debug HUD changes every frame and
// would hide exactly the signal we are looking for), and prints
//     index,pts_seconds,changed_pixels,mean_abs_diff
// A logic frame the game never computed shows up as a frame that is nearly
// identical to its predecessor.
//
// usage: vdiff <video> <l,t,r,b> [<mask l,t,r,b>;<mask>...] [threshold]
import AVFoundation
import Foundation

let args = CommandLine.arguments
guard args.count >= 3 else { FileHandle.standardError.write("usage: vdiff <video> <l,t,r,b> [masks] [thr]\n".data(using:.utf8)!); exit(1) }
let url = URL(fileURLWithPath: args[1])
let c = args[2].split(separator: ",").map { Int($0)! }
let (cl, ct, cr, cb) = (c[0], c[1], c[2], c[3])
var masks: [[Int]] = []
if args.count > 3 && !args[3].isEmpty {
    for m in args[3].split(separator: ";") { masks.append(m.split(separator: ",").map { Int($0)! }) }
}
let thr = args.count > 4 ? Int(args[4])! : 24

let asset = AVAsset(url: url)
guard let track = asset.tracks(withMediaType: .video).first,
      let reader = try? AVAssetReader(asset: asset) else { exit(2) }
let out = AVAssetReaderTrackOutput(track: track,
    outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
out.alwaysCopiesSampleData = false
reader.add(out)
reader.startReading()

let W = cr - cl, H = cb - ct
var prev = [UInt8](repeating: 0, count: W * H)
var cur  = [UInt8](repeating: 0, count: W * H)
var have = false
var idx = 0
print("index,pts,changed,meanabs")
while let sb = out.copyNextSampleBuffer() {
    guard let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
    let pts = CMSampleBufferGetPresentationTimeStamp(sb).seconds
    CVPixelBufferLockBaseAddress(pb, .readOnly)
    let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
    let stride = CVPixelBufferGetBytesPerRow(pb)
    for y in 0..<H {
        let row = base + (y + ct) * stride
        for x in 0..<W {
            let p = row + (x + cl) * 4
            // BGRA -> luma, integer weights
            cur[y*W + x] = UInt8((Int(p[2]) * 77 + Int(p[1]) * 150 + Int(p[0]) * 29) >> 8)
        }
    }
    CVPixelBufferUnlockBaseAddress(pb, .readOnly)
    for m in masks {
        let l = max(m[0]-cl,0), t = max(m[1]-ct,0), r = min(m[2]-cl,W), b = min(m[3]-ct,H)
        if l<r && t<b { for y in t..<b { for x in l..<r { cur[y*W+x] = 0 } } }
    }
    if have {
        var n = 0, s = 0
        for i in 0..<(W*H) {
            let d = abs(Int(cur[i]) - Int(prev[i]))
            s += d
            if d > thr { n += 1 }
        }
        print("\(idx),\(String(format: "%.4f", pts)),\(n),\(String(format: "%.4f", Double(s)/Double(W*H)))")
    }
    swap(&prev, &cur)
    have = true
    idx += 1
}
