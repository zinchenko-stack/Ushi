//
//  LiveTranscriberTests.swift
//
//  Живая расшифровка: звук режется на куски в паузах, без пропусков и повторов;
//  реплики одного говорящего склеиваются через границу кусков.
//

import XCTest
@testable import UshiNextCore

final class LiveTranscriberTests: XCTestCase {
    private let rate = LiveChunker.rate

    /// «Речь» (тон) кусками по `speech` секунд с паузами `pause` секунд.
    private func speechWithPauses(total: Double, speech: Double, pause: Double) -> [Float] {
        let n = Int(total * Double(rate))
        return (0..<n).map { i in
            let t = Double(i) / Double(rate)
            let inSpeech = t.truncatingRemainder(dividingBy: speech + pause) < speech
            return inSpeech ? Float(0.2 * sin(2 * .pi * 220 * t)) : 0
        }
    }

    /// Подаём звук порциями по 10 мс, как приходит из записи.
    private func feed(_ left: [Float], right: [Float]? = nil, into chunker: inout LiveChunker) -> [LiveChunker.Chunk] {
        var chunks: [LiveChunker.Chunk] = []
        var i = 0
        while i < left.count {
            let end = min(i + 160, left.count)
            chunks += chunker.append(left: Array(left[i..<end]), right: right.map { Array($0[i..<end]) })
            i = end
        }
        if let last = chunker.flush() { chunks.append(last) }
        return chunks
    }

    func testCutsInPausesWithoutLossOrRepeats() {
        let audio = speechWithPauses(total: 120, speech: 7, pause: 1)
        var chunker = LiveChunker(stereo: false)
        let chunks = feed(audio, into: &chunker)

        XCTAssertGreaterThan(chunks.count, 2)
        // Встык: каждый кусок начинается там, где кончился предыдущий, и вместе они — весь звук.
        var position = 0
        for chunk in chunks {
            XCTAssertEqual(chunk.start, position)
            position += chunk.left.count
        }
        XCTAssertEqual(chunks.flatMap(\.left), audio)
        // Режем в тишине и не короче, чем положено в этом месте записи (кроме последнего).
        for chunk in chunks.dropLast() {
            XCTAssertGreaterThanOrEqual(chunk.left.count, LiveChunker.limits(forPosition: chunk.start).min)
            XCTAssertEqual(audio[chunk.start + chunk.left.count - 1], 0, "кусок обрезан не в паузе")
        }
    }

    /// В начале куски короткие, чтобы текст появился сразу: ~5 с, потом ~15 с, после минуты ~30 с.
    func testChunksAreShortAtStartAndLongerLater() {
        let audio = speechWithPauses(total: 150, speech: 2.5, pause: 0.5)
        var chunker = LiveChunker(stereo: false)
        let chunks = feed(audio, into: &chunker).dropLast()
        let seconds = chunks.map { Double($0.left.count) / Double(rate) }
        XCTAssertLessThanOrEqual(seconds[0], 8)
        for (chunk, length) in zip(chunks, seconds) {
            let at = Double(chunk.start) / Double(rate)
            switch at {
            case 5..<60: XCTAssert((12...20).contains(length), "в \(at) с кусок \(length) с")
            case 60...:  XCTAssert((25...40).contains(length), "в \(at) с кусок \(length) с")
            default: break
            }
        }
    }

    func testWithoutPausesCutsAtMaximumLength() {
        let audio = speechWithPauses(total: 100, speech: 1_000, pause: 0)
        var chunker = LiveChunker(stereo: false)
        let chunks = feed(audio, into: &chunker)
        XCTAssertEqual(chunks.flatMap(\.left), audio)
        for chunk in chunks.dropLast() {
            XCTAssertLessThanOrEqual(chunk.left.count, 40 * rate)
        }
    }

    func testStereoKeepsChannelsAligned() {
        let mic = speechWithPauses(total: 60, speech: 5, pause: 1)
        let system = speechWithPauses(total: 60, speech: 3, pause: 2).map { $0 * 0.5 }
        var chunker = LiveChunker(stereo: true)
        let chunks = feed(mic, right: system, into: &chunker)
        XCTAssertEqual(chunks.flatMap(\.left), mic)
        XCTAssertEqual(chunks.flatMap { $0.right ?? [] }, system)
    }

    func testTurnsOfSameSpeakerMergeAcrossChunks() {
        var turns = LiveTranscript.merge([], [
            LiveTurn(speaker: "Собеседник", text: "Давайте начнём", start: 0),
            LiveTurn(speaker: "Я", text: "Да,", start: 0),
        ])
        turns = LiveTranscript.merge(turns, [
            LiveTurn(speaker: "Я", text: "конечно.", start: 20),
            LiveTurn(speaker: "Собеседник", text: "Отлично.", start: 20),
        ])
        XCTAssertEqual(turns.map(\.speaker), ["Собеседник", "Я", "Собеседник"])
        XCTAssertEqual(turns[1].text, "Да, конечно.")
        XCTAssertEqual(LiveTranscript.format(turns), "Собеседник: Давайте начнём\n\nЯ: Да, конечно.\n\nСобеседник: Отлично.")
    }

    func testDetectedLanguageParsing() {
        let log = "whisper_full: ...\nauto-detected language: ru (p = 0.732839)\n"
        let detected = TranscriptionService.detectedLanguage(in: log)
        XCTAssertEqual(detected?.code, "ru")
        XCTAssertEqual(detected?.probability ?? 0, 0.732839, accuracy: 1e-6)
        XCTAssertNil(TranscriptionService.detectedLanguage(in: "nothing"))
    }
}
