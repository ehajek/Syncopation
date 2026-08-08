// AudioConvert.swift — FLAC → ALAC entirely in-process.
//
// The App Store sandbox does not extend a security-scoped grant to child
// processes, so shelling out to /usr/bin/afconvert cannot read the user's
// music or write to the iPod. Everything here runs inside the app, using the
// access the app already holds. It also removes the last external dependency
// and the descriptor pressure that came with spawning thousands of processes.
//
// Output targets what click-wheel iPods actually play: 16-bit ALAC at
// 44.1 or 48 kHz. Hi-res sources are resampled down; nothing above 48 kHz
// and nothing deeper than 16-bit ever reaches the device.
//
// Copyright (C) 2026 Eddie Hajek
// Licensed under the GNU General Public License v3.0 — see the LICENSE file.

import Foundation
import AVFoundation

enum AudioConvertError: LocalizedError {
    case unreadable(String)
    case noAudioTrack
    case writerSetupFailed(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .unreadable(let why): return "Could not read the audio file: \(why)"
        case .noAudioTrack: return "The file contains no audio track."
        case .writerSetupFailed(let why): return "Could not start the converter: \(why)"
        case .failed(let why): return "Conversion failed: \(why)"
        }
    }
}

enum AudioConverter {

    /// The rate an iPod can actually play, given a source rate.
    /// 88.2/176.4 halve to 44.1; 96/192 halve to 48; anything already legal
    /// is left alone.
    static func iPodSampleRate(for sourceRate: Int) -> Int {
        let rate = sourceRate > 0 ? sourceRate : 44_100
        guard rate > 48_000 else { return rate }
        return rate % 44_100 == 0 ? 44_100 : 48_000
    }

    /// Converts any CoreAudio-readable file to 16-bit ALAC in an .m4a
    /// container. Runs synchronously on the calling (worker) thread.
    static func convertToALAC(source: URL, output: URL, sourceRate: Int) throws {
        let asset = AVURLAsset(url: source)
        guard let track = asset.tracks(withMediaType: .audio).first else {
            throw AudioConvertError.noAudioTrack
        }

        let rate = iPodSampleRate(for: sourceRate)
        let channels = min(channelCount(of: track), 2)   // iPods are stereo only

        // Decode to 16-bit interleaved PCM at the target rate. Doing the depth
        // conversion here is what keeps 32-bit ALAC — which iPod firmware
        // can't reliably decode — from ever being produced.
        let readerSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let writerSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatAppleLossless,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitDepthHintKey: 16,
        ]

        let reader: AVAssetReader
        let writer: AVAssetWriter
        do {
            reader = try AVAssetReader(asset: asset)
            try? FileManager.default.removeItem(at: output)
            writer = try AVAssetWriter(outputURL: output, fileType: .m4a)
        } catch {
            throw AudioConvertError.writerSetupFailed(error.localizedDescription)
        }

        let readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: readerSettings)
        readerOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(readerOutput) else {
            throw AudioConvertError.unreadable("this format can't be decoded")
        }
        reader.add(readerOutput)

        let writerInput = AVAssetWriterInput(mediaType: .audio, outputSettings: writerSettings)
        writerInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(writerInput) else {
            throw AudioConvertError.writerSetupFailed("Apple Lossless output was refused")
        }
        writer.add(writerInput)

        guard reader.startReading() else {
            throw AudioConvertError.unreadable(reader.error?.localizedDescription ?? "unknown error")
        }
        guard writer.startWriting() else {
            throw AudioConvertError.writerSetupFailed(
                writer.error?.localizedDescription ?? "unknown error")
        }
        writer.startSession(atSourceTime: .zero)

        // Pull samples on a private queue and block until it finishes; the
        // caller is a background worker that expects synchronous behaviour.
        let queue = DispatchQueue(label: "com.eddiehajek.syncopation.convert")
        let done = DispatchSemaphore(value: 0)
        writerInput.requestMediaDataWhenReady(on: queue) {
            while writerInput.isReadyForMoreMediaData {
                guard reader.status == .reading,
                      let buffer = readerOutput.copyNextSampleBuffer() else {
                    writerInput.markAsFinished()
                    done.signal()
                    return
                }
                if !writerInput.append(buffer) {
                    reader.cancelReading()
                    writerInput.markAsFinished()
                    done.signal()
                    return
                }
            }
        }
        done.wait()

        let finished = DispatchSemaphore(value: 0)
        writer.finishWriting { finished.signal() }
        finished.wait()

        if reader.status == .failed {
            try? FileManager.default.removeItem(at: output)
            throw AudioConvertError.failed(reader.error?.localizedDescription ?? "read error")
        }
        if writer.status != .completed {
            try? FileManager.default.removeItem(at: output)
            throw AudioConvertError.failed(writer.error?.localizedDescription ?? "write error")
        }
    }

    private static func channelCount(of track: AVAssetTrack) -> Int {
        for desc in track.formatDescriptions {
            let fd = desc as! CMFormatDescription
            if let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd)?.pointee {
                return Int(asbd.mChannelsPerFrame)
            }
        }
        return 2
    }
}
