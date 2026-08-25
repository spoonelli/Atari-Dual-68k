// hudscan.swift -- read the core's on-screen debug HUD from every frame of a
// capture, in one sequential pass (AVAssetReader, so frame N really is frame N).
//
// The overlay is core_top.v's 16-slot hex row drawn in its 4x6 `hexfont` on a
// dark-navy box.  On page 0 (mode digit == 0) the fields are
//     slots 0-3   vcyc  = video-CPU bus cycles in the previous frame
//     slots 5-8   ecyc  = extra-CPU bus cycles in the previous frame
//     slots 10-13 coin/credits,  slot 15 = debug page
// Any glyph that does not match a font template within 2 pixels is reported
// as '?' rather than guessed.
//
// usage: hudscan <video> <boxl,boxt,boxr,boxb>  -> CSV: index,pts,vcyc,ecyc,cc,mode,raw
//        (box = the overlay rectangle; find it once with sim/tools/read_hud.py)
import AVFoundation
import Foundation

let FONT: [[Int]] = [
 [0xF,0x9,0x9,0x9,0x9,0xF],[0x2,0x6,0x2,0x2,0x2,0x7],[0xF,0x1,0xF,0x8,0x8,0xF],[0xF,0x1,0x7,0x1,0x1,0xF],
 [0x9,0x9,0xF,0x1,0x1,0x1],[0xF,0x8,0xF,0x1,0x1,0xF],[0xF,0x8,0xF,0x9,0x9,0xF],[0xF,0x1,0x2,0x4,0x4,0x4],
 [0xF,0x9,0xF,0x9,0x9,0xF],[0xF,0x9,0xF,0x1,0x1,0xF],[0x6,0x9,0xF,0x9,0x9,0x9],[0xE,0x9,0xE,0x9,0x9,0xE],
 [0xF,0x8,0x8,0x8,0x8,0xF],[0xE,0x9,0x9,0x9,0x9,0xE],[0xF,0x8,0xE,0x8,0x8,0xF],[0xF,0x8,0xE,0x8,0x8,0x8]]
var TPL = [[Int]]()
for g in FONT { var b = [Int](); for r in g { for c in 0..<4 { b.append((r >> (3-c)) & 1) } }; TPL.append(b) }

let args = CommandLine.arguments
let box = args[2].split(separator: ",").map { Int($0)! }
let (bx0, by0, bx1, by1) = (box[0], box[1], box[2], box[3])
let asset = AVAsset(url: URL(fileURLWithPath: args[1]))
guard let track = asset.tracks(withMediaType: .video).first,
      let reader = try? AVAssetReader(asset: asset) else { exit(2) }
let out = AVAssetReaderTrackOutput(track: track,
    outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
out.alwaysCopiesSampleData = false
reader.add(out); reader.startReading()

print("index,pts,vcyc,ecyc,cc,mode,raw")
var idx = 0
while let sb = out.copyNextSampleBuffer() {
    guard let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
    let pts = CMSampleBufferGetPresentationTimeStamp(sb).seconds
    CVPixelBufferLockBaseAddress(pb, .readOnly)
    let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
    let stride = CVPixelBufferGetBytesPerRow(pb)
    let W = CVPixelBufferGetWidth(pb), H = CVPixelBufferGetHeight(pb)
    @inline(__always) func px(_ x: Int, _ y: Int) -> (Int, Int, Int) {
        let p = base + y * stride + x * 4
        return (Int(p[2]), Int(p[1]), Int(p[0]))
    }
    @inline(__always) func isYel(_ x: Int, _ y: Int) -> Bool {
        let (r,g,b) = px(x,y); return r > 170 && g > 170 && b < 120
    }
    @inline(__always) func isNavy(_ x: Int, _ y: Int) -> Bool {
        let (r,g,b) = px(x,y); return r < 70 && g < 70 && b > 60 && b < 160
    }
    // The overlay box is at a fixed screen position for a given capture, so
    // take it from the command line (l,t,r,b).  Auto-detection was tried and
    // rejected: the game's own sky/floor colours trip the same colour test.
    var line = "\(idx),\(String(format: "%.4f", pts)),,,,,NO-HUD"
    let sw = Double(bx1 - bx0 + 1) / 16.0, sh = Double(by1 - by0 + 1) / 6.0
    if bx1 < W && by1 < H {
        var raw = ""
        for slot in 0..<16 {
            var pat = [Int]()
            for fy in 0..<6 {
                let yy = by0 + Int((Double(fy) + 0.5) * sh)
                for fx in 0..<4 {
                    let xx = bx0 + Int((Double(slot) + (Double(fx) + 0.5) / 4.0) * sw)
                    pat.append(isYel(xx, yy) ? 1 : 0)
                }
            }
            var best = -1, bd = 99
            for d in 0..<16 {
                var dd = 0
                for i in 0..<24 where TPL[d][i] != pat[i] { dd += 1 }
                if dd < bd { bd = dd; best = d }
            }
            raw += bd <= 2 ? String(format: "%X", best) : "?"
        }
        let a = Array(raw)
        func f(_ r: Range<Int>) -> String { String(a[r]) }
        line = "\(idx),\(String(format: "%.4f", pts)),\(f(0..<4)),\(f(5..<9)),\(f(10..<14)),\(f(15..<16)),\(raw)"
    }
    CVPixelBufferUnlockBaseAddress(pb, .readOnly)
    print(line)
    idx += 1
}
