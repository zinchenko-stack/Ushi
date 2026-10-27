//
//  LiveTranscriberRealAudioTests.swift
//
//  Живая расшифровка на настоящей записи созвона и настоящем whisper.
//  Запускается, только если заданы USHI_WHISPER_CLI и USHI_LIVE_TEST_AUDIO
//  (стерео-дорожка Ushi: L = микрофон, R = система); иначе пропускается.
//  Итоговый текст пишется в USHI_LIVE_TEST_OUT — для сравнения с обычной расшифровкой.
//

import XCTest
import AVFoundation
@testable import UshiNextCore

@MainActor
final class LiveTranscriberRealAudioTests: XCTestCase {
    func testRealRecordingTranscribesInChunks() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["USHI_WHISPER_CLI"] != nil, let audioPath = env["USHI_LIVE_TEST_AUDIO"] else {
            throw XCTSkip("нет USHI_WHISPER_CLI / USHI_LIVE_TEST_AUDIO")
        }
        let seconds = Double(env["USHI_LIVE_TEST_SECONDS"] ?? "180") ?? 180
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: audioPath))
        let format = file.processingFormat
        XCTAssertEqual(format.sampleRate, 48_000)
        let frames = AVAudioFrameCount(min(Double(file.length), seconds * format.sampleRate))
        let buf = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        try file.read(into: buf, frameCount: frames)
        let n = Int(buf.frameLength)
        let mic = Array(UnsafeBufferPointer(start: buf.floatChannelData![0], count: n))
        let system = Array(UnsafeBufferPointer(start: buf.floatChannelData![1], count: n))

        let live = LiveTranscript(projectName: "тест")
        // Как в записи: порциями по 10 мс.
        let started = Date()
        var i = 0
        while i < n {
            let end = min(i + 480, n)
            let m = Array(mic[i..<end]), s = Array(system[i..<end])
            live.engine.append(microphone: m, system: s, mix: zip(m, s).map(+))
            i = end
        }
        let text = await live.finish()
        let elapsed = Date().timeIntervalSince(started)
        let result = try XCTUnwrap(text, "какой-то кусок не распознался")
        print("LIVE: \(live.turns.count) реплик, \(result.count) символов за \(Int(elapsed)) с на \(Int(seconds)) с звука")
        if let out = env["USHI_LIVE_TEST_OUT"] {
            try result.write(toFile: out, atomically: true, encoding: .utf8)
        }
        XCTAssertGreaterThan(result.count, Int(seconds) * 5, "подозрительно мало текста")
    }
}
