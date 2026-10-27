//
//  TranscriptionService.swift
//  ushi
//
//  Локальная транскрипция через whisper.cpp. Бинарь whisper-cli бандлится
//  в ushi.app/Contents/Resources/ (статический, Metal embedded, см. Phase 2).
//  Fallback на /opt/homebrew/bin/whisper-cli для разработки.
//  Шаги: m4a -> wav (afconvert) -> whisper-cli -> .txt
//  Если у записи есть голосовая дорожка (стерео: L = микрофон, R = система),
//  распознаём её с --diarize: whisper сравнивает громкость каналов на каждом
//  сегменте, а мы превращаем его метки в «Я:» / «Собеседник:».
//

import Foundation

enum TranscriptionError: LocalizedError {
    case binaryNotFound(String)
    case modelNotFound(String)
    case conversionFailed(String)
    case whisperFailed(String)
    case outputMissing

    var errorDescription: String? {
        switch self {
        case .binaryNotFound:           return "Не удалось найти распознавалку речи внутри приложения. Это баг сборки — напиши автору."
        case .modelNotFound:            return "Модель распознавания речи не установлена. Перезапусти Ushi — должно открыться окно скачивания."
        case .conversionFailed(let msg): return "Не удалось подготовить аудио к распознаванию: \(msg)"
        case .whisperFailed(let msg):   return "Распознавалка завершилась с ошибкой: \(msg)"
        case .outputMissing:            return "Распознавалка не создала текстовый файл — попробуй ещё раз."
        }
    }
}

struct TranscriptionService {

    private static let binaryCandidates = [
        "/opt/homebrew/bin/whisper-cli",
        "/opt/homebrew/bin/whisper-cpp",
        "/usr/local/bin/whisper-cli",
        "/usr/local/bin/whisper-cpp",
    ]

    static func modelURL() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".ushi/models/ggml-large-v3-turbo.bin")
    }

    static func isModelInstalled() -> Bool {
        FileManager.default.fileExists(atPath: modelURL().path)
    }

    static func vadModelURL() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".ushi/models/ggml-silero-v5.1.2.bin")
    }

    /// VAD-модель silero (~865 КБ) — отсекает тишину, чтобы whisper не галлюцинировал на ней.
    private static let vadModelDownloadURL = URL(string:
        "https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v5.1.2.bin")!

    private static func resolveBinary() -> String? {
        // Для проверок вне приложения (тесты): явный путь к whisper-cli.
        if let path = ProcessInfo.processInfo.environment["USHI_WHISPER_CLI"],
           FileManager.default.fileExists(atPath: path) {
            return path
        }
        if let bundled = Bundle.main.url(forResource: "whisper-cli", withExtension: nil),
           FileManager.default.fileExists(atPath: bundled.path) {
            return bundled.path
        }

        return binaryCandidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    /// Гарантирует наличие VAD-модели: если нет — пытается скачать.
    /// Возвращает путь, если модель доступна, иначе nil (тогда транскрибируем без VAD).
    private static func ensureVADModel() async -> URL? {
        let url = vadModelURL()
        if FileManager.default.fileExists(atPath: url.path) { return url }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let (tmp, response) = try await URLSession.shared.download(from: vadModelDownloadURL)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                try? FileManager.default.removeItem(at: tmp)
                return nil
            }
            try? FileManager.default.removeItem(at: url)
            try FileManager.default.moveItem(at: tmp, to: url)
            return url
        } catch {
            print("⚠️ VAD model download failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Пост-фильтр: выкидывает известные галлюцинации whisper (титры из YouTube,
    /// которые он дорисовывает на тишине) и схлопывает подряд идущие повторы строк.
    static func cleanTranscript(_ raw: String) -> String {
        // Подстроки, которых в реальной речи не бывает — строку целиком выкидываем.
        let bannedSubstrings = ["dimatorzok", "amara.org", "subtitles by", "редактор субтитров"]
        // Фразы-галлюцинации целиком (после нормализации).
        let bannedExact: Set<String> = [
            "продолжение следует",
            "спасибо за просмотр",
            "спасибо за внимание",
            "подписывайтесь на канал",
            "ставьте лайки",
        ]

        var kept: [String] = []
        var lastNorm: String?

        for rawLine in raw.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            let norm = line.lowercased()
                .trimmingCharacters(in: CharacterSet(charactersIn: " \t.,!?…-—\"'«»()"))

            if bannedSubstrings.contains(where: { norm.contains($0) }) { continue }
            if bannedExact.contains(norm) { continue }
            if norm.hasPrefix("субтитр") { continue }

            // Схлопываем подряд идущие одинаковые строки (типичный луп галлюцинации).
            if norm == lastNorm { continue }
            lastNorm = norm
            kept.append(line)
        }

        return kept.joined(separator: "\n")
    }

    /// `outputDirectory` — куда положить итоговый .txt. По умолчанию рядом с аудио (старое поведение);
    /// в проде передаётся `AppSettings.transcriptsDirectory()`, чтобы транскрипты не засоряли
    /// пользовательскую папку с медиа.
    static func transcribe(
        audioURL: URL,
        voiceTrackURL: URL? = nil,
        language: String? = nil,
        outputDirectory: URL? = nil
    ) async throws -> URL {
        // nil → берём язык из настроек (Авто/Русский/Английский).
        let language = language ?? AppSettings.transcriptionLanguage().rawValue
        guard let binary = resolveBinary() else {
            throw TranscriptionError.binaryNotFound(binaryCandidates.joined(separator: ", "))
        }
        let model = modelURL()
        guard FileManager.default.fileExists(atPath: model.path) else {
            throw TranscriptionError.modelNotFound(model.path)
        }

        // Запрещаем системе уходить в idle-сон, пока идёт транскрипция.
        // (Сон по закрытию крышки этим не отключается — это требует caffeinate.)
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.idleSystemSleepDisabled, .userInitiated],
            reason: "ushi transcription"
        )
        defer { ProcessInfo.processInfo.endActivity(activity) }

        #if DEBUG
        print("🧠 [transcribe] input: \(audioURL.path)")
        let t0 = Date()
        #endif

        // Голосовая дорожка — тот же звук, но с каналами по источникам. Если её
        // конвертация не удалась, молча откатываемся на обычный моно-микс.
        // Отдельная рабочая папка: WAV на входе и соседние файлы не трогаем.
        let workDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }
        let wavURL = workDir.appendingPathComponent("input.wav")
        var diarize = false
        if let voiceTrackURL,
           FileManager.default.fileExists(atPath: voiceTrackURL.path),
           (try? await convertToWav(input: voiceTrackURL, output: wavURL, channels: 2)) != nil {
            diarize = true
        } else {
            try await convertToWav(input: audioURL, output: wavURL, channels: 1)
        }

        #if DEBUG
        print("🧠 [transcribe] wav ready in \(String(format: "%.1f", Date().timeIntervalSince(t0)))s")
        let t1 = Date()
        #endif

        // VAD-модель (silero) — отсекает тишину. Если её нет/не скачалась, идём без VAD.
        let vadModel = await ensureVADModel()

        // outputPrefix управляет тем, КУДА whisper-cli напишет .txt: он добавит ".txt".
        // Кладём prefix в outputDirectory если задан, иначе — рядом с аудио (старое поведение).
        // Имена загруженных файлов могут совпадать в разных проектах.
        let baseName = UUID().uuidString
        let outputDir = outputDirectory ?? audioURL.deletingLastPathComponent()
        if outputDirectory != nil {
            try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        }
        let outputPrefix = outputDir.appendingPathComponent(baseName).path

        _ = try await runWhisper(
            binary: binary,
            model: model.path,
            wavPath: wavURL.path,
            language: language,
            outputPrefix: outputPrefix,
            vadModel: vadModel,
            diarize: diarize
        )

        #if DEBUG
        print("🧠 [transcribe] whisper done in \(String(format: "%.1f", Date().timeIntervalSince(t1)))s")
        #endif

        let txtURL = outputDir.appendingPathComponent("\(baseName).txt")
        guard FileManager.default.fileExists(atPath: txtURL.path) else {
            throw TranscriptionError.outputMissing
        }

        // Пост-фильтр галлюцинаций (сетка безопасности поверх VAD).
        if let raw = try? String(contentsOf: txtURL, encoding: .utf8) {
            let cleaned = diarize ? labelSpeakers(raw) : cleanTranscript(raw)
            try? cleaned.write(to: txtURL, atomically: true, encoding: .utf8)
        }

        return txtURL
    }

    // MARK: - Кусок живой расшифровки

    /// Распознаёт готовый WAV 16 кГц (кусок записи во время созвона) теми же
    /// настройками, что и запись целиком. Возвращает сырой вывод whisper и язык,
    /// если он определялся автоматически (`language == "auto"`).
    static func transcribeChunk(
        wavURL: URL, diarize: Bool, language: String
    ) async throws -> (raw: String, detectedLanguage: String?, probability: Double?) {
        guard let binary = resolveBinary() else {
            throw TranscriptionError.binaryNotFound(binaryCandidates.joined(separator: ", "))
        }
        let model = modelURL()
        guard FileManager.default.fileExists(atPath: model.path) else {
            throw TranscriptionError.modelNotFound(model.path)
        }
        let vadModel = await ensureVADModel()
        let prefix = wavURL.deletingPathExtension().path
        let stderr = try await runWhisper(
            binary: binary, model: model.path, wavPath: wavURL.path,
            language: language, outputPrefix: prefix, vadModel: vadModel, diarize: diarize
        )
        let txtURL = URL(fileURLWithPath: prefix + ".txt")
        defer { try? FileManager.default.removeItem(at: txtURL) }
        // Нет речи — whisper может не создать файл: это пустой кусок, не ошибка.
        let raw = (try? String(contentsOf: txtURL, encoding: .utf8)) ?? ""
        let detected = detectedLanguage(in: String(decoding: stderr, as: UTF8.self))
        return (raw, detected?.code, detected?.probability)
    }

    /// «auto-detected language: ru (p = 0.998040)» из stderr whisper-cli.
    static func detectedLanguage(in log: String) -> (code: String, probability: Double)? {
        guard let range = log.range(of: "auto-detected language: ") else { return nil }
        let rest = log[range.upperBound...]
        let code = rest.prefix { $0.isLetter }
        guard !code.isEmpty else { return nil }
        var probability = 0.0
        if let p = rest.range(of: "p = ") {
            probability = Double(rest[p.upperBound...].prefix { $0.isNumber || $0 == "." }) ?? 0
        }
        return (String(code), probability)
    }

    // MARK: - Говорящие

    nonisolated static let selfLabel = "Я"
    nonisolated static let otherLabel = "Собеседник"

    /// Превращает вывод `whisper-cli --diarize` в реплики по говорящим.
    /// Вход: строки вида `(speaker 0) текст`, где 0 = левый канал (микрофон),
    /// 1 = правый (система), `?` = громкость каналов сравнима.
    /// Выход: подряд идущие сегменты одного говорящего склеены в одну реплику,
    /// реплики разделены пустой строкой: «Я: …», «Собеседник: …».
    static func labelSpeakers(_ raw: String) -> String {
        speakerTurns(raw).map { "\($0.speaker): \($0.text)" }.joined(separator: "\n\n")
    }

    /// То же, что `labelSpeakers`, но репликами — для живой расшифровки, где
    /// куски склеиваются между собой.
    static func speakerTurns(_ raw: String) -> [(speaker: String, text: String)] {
        var turns: [(speaker: String, text: String)] = []
        var lastNorm: String?

        for rawLine in raw.components(separatedBy: .newlines) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            var speaker: String?
            if line.hasPrefix("(speaker "), let close = line.firstIndex(of: ")") {
                let id = line[line.index(line.startIndex, offsetBy: 9)..<close]
                switch id {
                case "0": speaker = selfLabel
                case "1": speaker = otherLabel
                default:  speaker = nil      // «?» — непонятно, приклеим к предыдущему
                }
                line = String(line[line.index(after: close)...])
                    .trimmingCharacters(in: .whitespaces)
            }

            // Тот же фильтр галлюцинаций, что и для обычного транскрипта, но по тексту без метки.
            let text = cleanTranscript(line)
            if text.isEmpty { continue }
            let norm = text.lowercased()
            if norm == lastNorm { continue }
            lastNorm = norm

            let who = speaker ?? turns.last?.speaker ?? otherLabel
            if let last = turns.last, last.speaker == who {
                turns[turns.count - 1].text += " " + text
            } else {
                turns.append((who, text))
            }
        }

        return turns
    }

    /// Текст без меток говорящих — для авто-названия и поиска по смыслу.
    nonisolated static func removingSpeakerLabels(_ text: String) -> String {
        text.components(separatedBy: "\n").map { line in
            for label in [selfLabel, otherLabel] where line.hasPrefix(label + ":") {
                return String(line.dropFirst(label.count + 1)).trimmingCharacters(in: .whitespaces)
            }
            return line
        }.joined(separator: "\n")
    }

    // MARK: - afconvert

    private static func convertToWav(input: URL, output: URL, channels: Int) async throws {
        try? FileManager.default.removeItem(at: output)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        process.arguments = [
            input.path,
            output.path,
            "-d", "LEI16@16000",
            "-f", "WAVE",
            "-c", String(channels),
        ]
        process.standardError = Pipe()
        process.standardOutput = Pipe()

        try await runProcess(process) { code, errData in
            if code != 0 {
                let msg = String(data: errData, encoding: .utf8) ?? "code \(code)"
                throw TranscriptionError.conversionFailed(msg)
            }
        }
    }

    // MARK: - whisper-cli

    private static func runWhisper(
        binary: String, model: String, wavPath: String,
        language: String, outputPrefix: String, vadModel: URL?, diarize: Bool
    ) async throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        var args = [
            "-m", model,
            "-f", wavPath,
            "-l", language,
            "-otxt",
            "-of", outputPrefix,
            "--suppress-nst",            // давим неречевые токены
            // Не подсказываем модели её же прошлый текст. С подсказкой одна
            // галлюцинация («Субтитры сделал…», повтор фразы) тянет за собой
            // следующие окна, и от часового созвона оставалось 3 абзаца.
            "--max-context", "0",
        ]
        if let vadModel {
            args += ["--vad", "--vad-model", vadModel.path]
        }
        if diarize {
            args.append("--diarize")     // стерео: метка говорящего по громкости каналов
        }
        process.arguments = args
        process.standardError = Pipe()
        process.standardOutput = Pipe()

        var log = Data()
        try await runProcess(process) { code, errData in
            if code != 0 {
                let msg = String(data: errData, encoding: .utf8) ?? "code \(code)"
                throw TranscriptionError.whisperFailed(msg)
            }
            log = errData
        }
        return log
    }

    // MARK: - Process helper

    private static func runProcess(
        _ process: Process,
        onExit: @escaping (Int32, Data) throws -> Void
    ) async throws {
        let errPipe = process.standardError as? Pipe
        let outPipe = process.standardOutput as? Pipe

        let errBox = DataBox()
        errPipe?.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                errBox.append(data)
            }
        }
        outPipe?.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
        }

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { proc in
                errPipe?.fileHandleForReading.readabilityHandler = nil
                outPipe?.fileHandleForReading.readabilityHandler = nil
                try? errPipe?.fileHandleForReading.close()
                try? outPipe?.fileHandleForReading.close()
                try? errPipe?.fileHandleForWriting.close()
                try? outPipe?.fileHandleForWriting.close()
                do {
                    try onExit(proc.terminationStatus, errBox.snapshot())
                    cont.resume()
                } catch {
                    cont.resume(throwing: error)
                }
            }
            do {
                try process.run()
            } catch {
                cont.resume(throwing: error)
            }
        }
    }
}

nonisolated private final class DataBox: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()
    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        data.append(chunk)
    }
    func snapshot() -> Data {
        lock.lock(); defer { lock.unlock() }
        return data
    }
}
