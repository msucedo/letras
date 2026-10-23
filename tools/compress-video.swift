// Comprime un video de pantalla a H.264 con un bitrate fijo (los presets de avconvert no lo dejan bajar).
// swiftc tools/compress-video.swift -o build/compress-video
// build/compress-video build/revision.mov dist/Letras-revision.mp4 1440 900 3000000 [inicio fin]
// inicio y fin, en segundos, recortan el video (por ejemplo 0 107).
import AVFoundation

let a = CommandLine.arguments
let src = URL(fileURLWithPath: a[1]), dst = URL(fileURLWithPath: a[2])
let w = Int(a[3])!, h = Int(a[4])!, bps = Int(a[5])!
try? FileManager.default.removeItem(at: dst)

let asset = AVURLAsset(url: src)
let reader = try AVAssetReader(asset: asset)
let inicio = a.count > 6 ? CMTime(seconds: Double(a[6])!, preferredTimescale: 600) : .zero
if a.count > 7 {
    reader.timeRange = CMTimeRange(start: inicio, end: CMTime(seconds: Double(a[7])!, preferredTimescale: 600))
}
let writer = try AVAssetWriter(outputURL: dst, fileType: .mp4)
writer.shouldOptimizeForNetworkUse = true

let vTrack = asset.tracks(withMediaType: .video)[0]
let vOut = AVAssetReaderTrackOutput(track: vTrack, outputSettings: [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange])
reader.add(vOut)
let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
    AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h,
    AVVideoScalingModeKey: AVVideoScalingModeResizeAspect,
    AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: bps,
                                      AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel]])
vIn.transform = vTrack.preferredTransform
writer.add(vIn)

var pairs = [(vOut as AVAssetReaderOutput, vIn)]
if let aTrack = asset.tracks(withMediaType: .audio).first {
    let aOut = AVAssetReaderTrackOutput(track: aTrack, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
    reader.add(aOut)
    let aIn = AVAssetWriterInput(mediaType: .audio, outputSettings: [
        AVFormatIDKey: kAudioFormatMPEG4AAC, AVNumberOfChannelsKey: 2, AVSampleRateKey: 44100, AVEncoderBitRateKey: 96000])
    writer.add(aIn)
    pairs.append((aOut, aIn))
}

reader.startReading()
writer.startWriting()
writer.startSession(atSourceTime: inicio)
let group = DispatchGroup()
for (i, (out, inp)) in pairs.enumerated() {
    group.enter()
    inp.requestMediaDataWhenReady(on: DispatchQueue(label: "q\(i)")) {
        while inp.isReadyForMoreMediaData {
            if let s = out.copyNextSampleBuffer() { inp.append(s) }
            else { inp.markAsFinished(); group.leave(); return }
        }
    }
}
group.wait()
let done = DispatchSemaphore(value: 0)
writer.finishWriting { done.signal() }
done.wait()
if writer.status != .completed { print("Error:", writer.error ?? reader.error ?? "?"); exit(1) }
print("OK")
