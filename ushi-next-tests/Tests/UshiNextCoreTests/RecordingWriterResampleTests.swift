//
//  RecordingWriterResampleTests.swift
//
//  Источник звука не на 48 кГц (AirPods в режиме звонка, 16/24 кГц) не должен
//  давать «электрический» звук: непрерывный тон после записи остаётся
//  непрерывным, без периодических дырок тишины.
//

import XCTest
import AVFoundation
import CoreMedia
@testable import UshiNextCore

final class RecordingWriterResampleTests: XCTestCase {

    func testContinuousToneAt48kHasNoHoles() throws {
        let holes = try zeroHoles(sourceRate: 48_000, framesPerBuffer: 512)
        XCTAssertEqual(holes, 0)
    }

    func testContinuousToneAt24kHasNoHoles() throws {
        let holes = try zeroHoles(sourceRate: 24_000, framesPerBuffer: 480)
        XCTAssertEqual(holes, 0)
    }

    func testContinuousToneAt16kHasNoHoles() throws {
        let holes = try zeroHoles(sourceRate: 16_000, framesPerBuffer: 320)
        XCTAssertEqual(holes, 0)
    }

    /// Bluetooth в режиме звонка отдаёт буферы с «дрожащими» метками времени
    /// (±3 мс). Раньше каждый буфер ставился строго по метке — между буферами
    /// появлялись дырки, а соседние наслаивались: «электрический» звук.
    func testJitteryTimestampsAt24kHaveNoHoles() throws {
        let holes = try zeroHoles(sourceRate: 24_000, framesPerBuffer: 480, jitter: 0.003)
        XCTAssertEqual(holes, 0)
    }

    /// Пишет 5 с тона 440 Гц буферами по `framesPerBuffer` с PTS по часам,
    /// возвращает число провалов (≥ 1 мс подряд почти нулевых сэмплов) в середине файла.
    private func zeroHoles(sourceRate: Double, framesPerBuffer: Int, jitter: Double = 0) throws -> Int {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("out.m4a")

        let writer = try RecordingWriter(outputURL: url, video: false, videoSize: .zero, videoBitrate: 0)
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                                 sampleRate: sourceRate, channels: 2, interleaved: false))
        let start = CMTime(seconds: 1_000, preferredTimescale: 1_000_000_000)
        let total = Int(sourceRate * 5)
        var written = 0
        var rng: UInt64 = 42
        while written < total {
            let buf = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format,
                                                     frameCapacity: AVAudioFrameCount(framesPerBuffer)))
            buf.frameLength = AVAudioFrameCount(framesPerBuffer)
            for c in 0..<2 {
                let ch = buf.floatChannelData![c]
                for i in 0..<framesPerBuffer {
                    ch[i] = 0.3 * sin(2 * .pi * 440 * Float(written + i) / Float(sourceRate))
                }
            }
            rng = rng &* 6364136223846793005 &+ 1442695040888963407
            let noise = (Double(rng >> 11) / Double(1 << 53) * 2 - 1) * jitter
            let pts = CMTimeAdd(start, CMTime(seconds: Double(written) / sourceRate + noise,
                                              preferredTimescale: 1_000_000_000))
            writer.appendAudio(buf, at: pts, source: .system)
            written += framesPerBuffer
        }
        writer.finishInputs()
        let done = expectation(description: "finish")
        Task { try? await writer.complete(); done.fulfill() }
        wait(for: [done], timeout: 10)

        let file = try AVAudioFile(forReading: url)
        let out = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                 frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: out)
        let samples = UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength))
        // Края (раскачка AAC) не считаем.
        let lo = 4_800, hi = samples.count - 4_800
        var holes = 0, run = 0
        for i in lo..<hi {
            if abs(samples[i]) < 0.01 { run += 1 } else {
                if run >= 48 { holes += 1 }
                run = 0
            }
        }
        return holes
    }
}
