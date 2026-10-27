import AppKit
import ScreenCaptureKit
import AVFoundation
import QuartzCore

// Port of record-display-spike.swift: display stream filtered to ONE lab window,
// cropped to its frame; actual backing scale and live mach timebase. No prompts.
final class Recorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let writer: AVAssetWriter, input: AVAssetWriterInput, adaptor: AVAssetWriterInputPixelBufferAdaptor
    let gray: FileHandle, csv: FileHandle, tick: Double
    var count = 0, started = false, failed = false
    init(out: URL, width: Int, height: Int) throws {
        writer = try AVAssetWriter(outputURL:out.appendingPathComponent("screen.mov"),fileType:.mov)
        input = AVAssetWriterInput(mediaType:.video,outputSettings:[AVVideoCodecKey:AVVideoCodecType.h264,
            AVVideoWidthKey:width,AVVideoHeightKey:height,
            AVVideoCompressionPropertiesKey:[AVVideoAverageBitRateKey:8_000_000,AVVideoExpectedSourceFrameRateKey:120]])
        input.expectsMediaDataInRealTime = true; writer.add(input)
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput:input,sourcePixelBufferAttributes:nil)
        var t = mach_timebase_info_data_t(); mach_timebase_info(&t); tick = Double(t.numer)/Double(t.denom)/1e9
        FileManager.default.createFile(atPath:out.appendingPathComponent("gray.bin").path,contents:nil)
        FileManager.default.createFile(atPath:out.appendingPathComponent("screen-frames.csv").path,
            contents:Data("index,display_monotonic_s,pts_s,callback_s,width,height,stride,video_appended\n".utf8))
        gray = try FileHandle(forWritingTo:out.appendingPathComponent("gray.bin"))
        csv = try FileHandle(forWritingTo:out.appendingPathComponent("screen-frames.csv")); try csv.seekToEnd()
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        // Delegate errors may arrive off the output queue; exit rather than race
        // and pretend a partial stream completed successfully.
        fputs("CAPTURE ERROR \(error)\n",stderr); exit(10)
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let dict = (CMSampleBufferGetSampleAttachmentsArray(sampleBuffer,createIfNecessary:false) as? [[SCStreamFrameInfo:Any]])?.first,
              let status = dict[.status] as? Int, status == SCFrameStatus.complete.rawValue,
              let display = dict[.displayTime] as? UInt64, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if !started { writer.startWriting(); writer.startSession(atSourceTime:pts); started = true }
        CVPixelBufferLockBaseAddress(buffer,.readOnly)
        let height = CVPixelBufferGetHeightOfPlane(buffer,0), stride = CVPixelBufferGetBytesPerRowOfPlane(buffer,0), width = CVPixelBufferGetWidthOfPlane(buffer,0)
        if let base = CVPixelBufferGetBaseAddressOfPlane(buffer,0) { gray.write(Data(bytes:base,count:height*stride)) }
        CVPixelBufferUnlockBaseAddress(buffer,.readOnly)
        let ok = input.isReadyForMoreMediaData && adaptor.append(buffer,withPresentationTime:pts)
        if !ok { failed = true }
        csv.write(Data("\(count),\(Double(display)*tick),\(CMTimeGetSeconds(pts)),\(CACurrentMediaTime()),\(width),\(height),\(stride),\(ok)\n".utf8))
        count += 1
    }
}

// Top-level Task keeps AppKit's main run loop available without a visible window.
@MainActor func capture() async throws {
    let args = Array(CommandLine.arguments.dropFirst())
    guard args.count == 5, args[0] == "--allow-capture", let pid = Int32(args[1]),
          let seconds = Double(args[3]), seconds > 0, seconds <= 60, args[4] == "120", CGPreflightScreenCaptureAccess() else {
        fputs("REFUSED: --allow-capture PID OUTPUT SECONDS 120 and pre-existing recording permission required\n",stderr); exit(3)
    }
    let out = URL(fileURLWithPath:args[2])
    var bytes = [CChar](repeating:0,count:4096)
    guard proc_pidpath(pid,&bytes,UInt32(bytes.count)) > 0 else { exit(3) }
    let executable = URL(fileURLWithPath:String(cString:bytes))
    let bundle = Bundle(url:executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent())
    guard bundle?.bundleIdentifier?.hasPrefix("com.taha.Attic.lab.canvas-") == true,
          bundle?.executableURL?.standardizedFileURL == executable.standardizedFileURL else { exit(3) }
    let content = try await SCShareableContent.excludingDesktopWindows(false,onScreenWindowsOnly:true)
    let owned = content.windows.filter { $0.owningApplication?.processID == pid && $0.windowLayer == 0 }
    guard owned.count == 1, let window = owned.first,
          let display = content.displays.first(where: { $0.frame.contains(window.frame) }),
          let screen = NSScreen.screens.first(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32) == display.displayID }),
          CGDisplayIsBuiltin(display.displayID) != 0, screen.maximumFramesPerSecond == 120 else { exit(4) }
    let filter = SCContentFilter(display:display,including:[window]), config = SCStreamConfiguration()
    config.sourceRect = CGRect(x:window.frame.minX-display.frame.minX,y:window.frame.minY-display.frame.minY,width:window.frame.width,height:window.frame.height)
    let scale = screen.backingScaleFactor
    config.width = Int(window.frame.width*scale); config.height = Int(window.frame.height*scale)
    config.minimumFrameInterval = CMTime(value:1,timescale:120);config.queueDepth = 6
    config.showsCursor = false;config.ignoreShadowsSingleWindow = true;config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
    let metadata: [String:Any] = ["pid":pid,"bundle":bundle!.bundleIdentifier!,"window_id":window.windowID,
        "window_frame_cg_pt":[window.frame.minX,window.frame.minY,window.frame.width,window.frame.height],
        "capture_type":"display including only owned window, cropped to window","scale":scale,
        "display_id":display.displayID,"display_builtin":true,"current_mode_hz":CGDisplayCopyDisplayMode(display.displayID)?.refreshRate ?? 0,
        "requested_fps":120,"advertised_max_hz":screen.maximumFramesPerSecond,"pixel_size":[config.width,config.height]]
    try JSONSerialization.data(withJSONObject:metadata,options:[.prettyPrinted,.sortedKeys]).write(to:out.appendingPathComponent("capture-settings.json"))
    let recorder = try Recorder(out:out,width:config.width,height:config.height)
    let queue = DispatchQueue(label:"canvas.lab.capture")
    let stream = SCStream(filter:filter,configuration:config,delegate:recorder)
    try stream.addStreamOutput(recorder,type:.screen,sampleHandlerQueue:queue)
    try await stream.startCapture()
    try Data("ready\n".utf8).write(to:out.appendingPathComponent("recording-ready.txt"))
    try await Task.sleep(for:.seconds(seconds))
    try await stream.stopCapture()
    // Drain all frame appends before finalizing the encoder.
    queue.sync { recorder.input.markAsFinished() }
    await recorder.writer.finishWriting()
    try recorder.gray.close();try recorder.csv.close()
    guard recorder.count > 0, !recorder.failed, recorder.writer.status == .completed else { exit(10) }
    exit(0)
}
guard CommandLine.arguments.contains("--allow-capture") else { fputs("REFUSED: capture opt-in required\n",stderr);exit(3) }
Task { @MainActor in
    do { try await capture() } catch { fputs("CAPTURE ERROR \(error)\n",stderr);exit(10) }
}
RunLoop.main.run()
