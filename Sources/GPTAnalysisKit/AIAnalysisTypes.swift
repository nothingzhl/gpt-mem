import Foundation

/// A module supplies facts and domain guidance; provider clients know nothing about the module.
public protocol AIAnalysisModule {
    func makeInput() throws -> AIAnalysisInput
}

public protocol AIProviderClient {
    func analyze(input: AIAnalysisInput, configuration: AIProviderConfiguration, apiKey: String?) async throws -> AIAnalysisResult
}

public enum AIJSONValue: Codable, Equatable {
    case object([String: AIJSONValue]), array([AIJSONValue]), string(String), number(Double), bool(Bool), null

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let item = try? value.decode(Bool.self) { self = .bool(item) }
        else if let item = try? value.decode(String.self) { self = .string(item) }
        else if let item = try? value.decode(Double.self) { self = .number(item) }
        else if let item = try? value.decode([AIJSONValue].self) { self = .array(item) }
        else { self = .object(try value.decode([String: AIJSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .object(let item): try value.encode(item)
        case .array(let item): try value.encode(item)
        case .string(let item): try value.encode(item)
        case .number(let item): try value.encode(item)
        case .bool(let item): try value.encode(item)
        case .null: try value.encodeNil()
        }
    }
}

public struct AIAnalysisFact: Codable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let data: AIJSONValue
    public init(id: String, title: String, data: AIJSONValue) { self.id = id; self.title = title; self.data = data }
}

public struct AIAnalysisSubject: Codable, Equatable, Identifiable {
    public let id: String
    public let label: String
    public let canInspect: Bool
    public init(id: String, label: String, canInspect: Bool) { self.id = id; self.label = label; self.canInspect = canInspect }
}

/// Domain wording travels with the frozen input, so future modules reuse the same report UI.
public struct AIAnalysisPresentation: Codable, Equatable {
    public let evidenceTitle: String
    public let hypothesesTitle: String
    public let nextStepsTitle: String
    public let interpretation: String
    public let privacyNotice: String
    public init(evidenceTitle: String, hypothesesTitle: String, nextStepsTitle: String,
                interpretation: String, privacyNotice: String) {
        self.evidenceTitle = evidenceTitle; self.hypothesesTitle = hypothesesTitle
        self.nextStepsTitle = nextStepsTitle; self.interpretation = interpretation; self.privacyNotice = privacyNotice
    }
    public var isValid: Bool {
        [evidenceTitle, hypothesesTitle, nextStepsTitle, interpretation, privacyNotice].allSatisfy {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.utf8.count <= 2_048
        }
    }
}

public struct AIAnalysisInput: Codable, Equatable {
    public let moduleID: String
    public let moduleTitle: String
    public let promptVersion: String
    public let guidance: String
    public let windowStart: Date
    public let windowEnd: Date
    public let facts: [AIAnalysisFact]
    public let subjects: [AIAnalysisSubject]
    public let context: String
    public let presentation: AIAnalysisPresentation?
    public let prompt: AIAnalysisPrompt?

    public init(moduleID: String, moduleTitle: String, promptVersion: String, guidance: String,
                windowStart: Date, windowEnd: Date, facts: [AIAnalysisFact], subjects: [AIAnalysisSubject], context: String = "", presentation: AIAnalysisPresentation? = nil, prompt: AIAnalysisPrompt? = nil) {
        self.moduleID = moduleID; self.moduleTitle = moduleTitle; self.promptVersion = promptVersion
        self.guidance = guidance; self.windowStart = windowStart; self.windowEnd = windowEnd
        self.facts = facts; self.subjects = subjects; self.context = context; self.presentation = presentation; self.prompt = prompt
    }

    public func applying(prompt: AIAnalysisPrompt?) throws -> AIAnalysisInput {
        try prompt?.validate()
        return AIAnalysisInput(moduleID: moduleID, moduleTitle: moduleTitle, promptVersion: promptVersion,
            guidance: guidance, windowStart: windowStart, windowEnd: windowEnd, facts: facts,
            subjects: subjects, context: context, presentation: presentation, prompt: prompt)
    }

    public func validated() throws -> Data {
        try prompt?.validate()
        guard !moduleID.isEmpty, !moduleTitle.isEmpty, !promptVersion.isEmpty,
              windowStart.timeIntervalSince1970.isFinite, windowEnd.timeIntervalSince1970.isFinite,
              windowEnd > windowStart, presentation?.isValid != false, !facts.isEmpty, facts.count <= 100,
              subjects.count <= 50, context.utf8.count <= 8_192, guidance.utf8.count <= 16_384 else {
            throw AIAnalysisError.invalidConfiguration("分析模块、时间范围或输入数量无效。")
        }
        let factIDs = facts.map(\.id), subjectIDs = subjects.map(\.id)
        guard Set(factIDs).count == factIDs.count, Set(subjectIDs).count == subjectIDs.count,
              factIDs.allSatisfy({ !$0.isEmpty && $0.count <= 100 }),
              subjectIDs.allSatisfy({ !$0.isEmpty && $0.count <= 100 }) else {
            throw AIAnalysisError.invalidConfiguration("分析证据和对象编号必须唯一且非空。")
        }
        let data = try AIAnalysisCodec.encoder().encode(self)
        guard data.count <= 131_072 else { throw AIAnalysisError.inputTooLarge }
        return data
    }
}

public struct AIObservation: Codable, Equatable {
    public let text: String
    public let evidenceIDs: [String]
    public init(text: String, evidenceIDs: [String]) { self.text = text; self.evidenceIDs = evidenceIDs }
}

public struct AIHypothesis: Codable, Equatable {
    public let title: String
    public let explanation: String
    public let evidenceIDs: [String]
    public let missingEvidence: [String]
    public init(title: String, explanation: String, evidenceIDs: [String], missingEvidence: [String]) {
        self.title = title; self.explanation = explanation; self.evidenceIDs = evidenceIDs; self.missingEvidence = missingEvidence
    }
}

public struct AINextStep: Codable, Equatable {
    public let subjectID: String?
    public let action: String
    public let purpose: String
    public init(subjectID: String?, action: String, purpose: String) { self.subjectID = subjectID; self.action = action; self.purpose = purpose }
}

public struct AIAnalysisResult: Codable, Equatable {
    public let summary: String
    public let observations: [AIObservation]
    public let hypotheses: [AIHypothesis]
    public let nextSteps: [AINextStep]
    public let limitations: [String]
    public init(summary: String, observations: [AIObservation], hypotheses: [AIHypothesis], nextSteps: [AINextStep], limitations: [String]) {
        self.summary = summary; self.observations = observations; self.hypotheses = hypotheses
        self.nextSteps = nextSteps; self.limitations = limitations
    }

    /// Citation validation does not establish the truth of the model's hypotheses.
    public func validate(against input: AIAnalysisInput) throws {
        func validText(_ text: String) -> Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.utf8.count <= 12_000 }
        guard validText(summary), !observations.isEmpty, observations.count <= 12,
              hypotheses.count <= 8, !nextSteps.isEmpty, nextSteps.count <= 10,
              !limitations.isEmpty, limitations.count <= 10, limitations.allSatisfy(validText) else {
            throw AIAnalysisError.invalidResponse("分析内容为空或超过允许长度。")
        }
        let availableEvidence = Set(input.facts.map(\.id))
        func validReferences(_ ids: [String]) -> Bool { !ids.isEmpty && ids.count <= 20 && ids.allSatisfy { availableEvidence.contains($0) } }
        for observation in observations {
            guard validText(observation.text), validReferences(observation.evidenceIDs) else {
                throw AIAnalysisError.invalidEvidence("分析引用了不存在的证据，或缺少依据。")
            }
        }
        for hypothesis in hypotheses {
            guard validText(hypothesis.title), validText(hypothesis.explanation), validReferences(hypothesis.evidenceIDs),
                  hypothesis.missingEvidence.count <= 10, hypothesis.missingEvidence.allSatisfy(validText) else {
                throw AIAnalysisError.invalidEvidence("原因假设缺少有效证据或内容不完整。")
            }
        }
        for step in nextSteps {
            guard validText(step.action), validText(step.purpose) else { throw AIAnalysisError.invalidResponse("检查建议不完整。") }
            if let id = step.subjectID {
                guard input.subjects.contains(where: { $0.id == id && $0.canInspect }) else {
                    throw AIAnalysisError.invalidEvidence("检查建议引用了不存在或当前不可检查的对象。")
                }
            }
        }
        guard try AIAnalysisCodec.encoder().encode(self).count <= 131_072 else { throw AIAnalysisError.invalidResponse("分析结果超过允许长度。") }
    }

    public static var jsonSchema: AIJSONValue {
        let text: AIJSONValue = .object(["type": .string("string")])
        let texts: AIJSONValue = .object(["type": .string("array"), "items": text])
        func object(_ properties: [String: AIJSONValue]) -> AIJSONValue {
            .object(["type": .string("object"), "properties": .object(properties),
                     "required": .array(properties.keys.sorted().map { .string($0) }), "additionalProperties": .bool(false)])
        }
        func array(_ value: AIJSONValue) -> AIJSONValue { .object(["type": .string("array"), "items": value]) }
        return object([
            "summary": text,
            "observations": array(object(["text": text, "evidenceIDs": texts])),
            "hypotheses": array(object(["title": text, "explanation": text, "evidenceIDs": texts, "missingEvidence": texts])),
            "nextSteps": array(object(["subjectID": .object(["type": .array([.string("string"), .string("null")])]), "action": text, "purpose": text])),
            "limitations": texts
        ])
    }
}

public struct AIAnalysisRecord: Codable, Equatable {
    public let moduleID: String
    public let moduleTitle: String
    public let providerID: UUID
    public let providerName: String
    public let model: String
    public let inputFingerprint: String
    public let windowStart: Date
    public let windowEnd: Date
    public let generatedAt: Date
    public let result: AIAnalysisResult
    public var wasCached: Bool
    public init(moduleID: String, moduleTitle: String, providerID: UUID, providerName: String, model: String,
                inputFingerprint: String, windowStart: Date, windowEnd: Date, generatedAt: Date = Date(), result: AIAnalysisResult, wasCached: Bool = false) {
        self.moduleID = moduleID; self.moduleTitle = moduleTitle; self.providerID = providerID; self.providerName = providerName
        self.model = model; self.inputFingerprint = inputFingerprint; self.windowStart = windowStart; self.windowEnd = windowEnd
        self.generatedAt = generatedAt; self.result = result; self.wasCached = wasCached
    }
}

public enum AIAnalysisCodec {
    public static func encoder(pretty: Bool = false) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        return encoder
    }
    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601; return decoder
    }
}

public enum AIAnalysisError: Error, LocalizedError, CustomStringConvertible {
    case invalidConfiguration(String), missingCredential, transport(String), httpStatus(Int)
    case invalidResponse(String), invalidEvidence(String), cancelled, inputTooLarge
    case generationLengthLimit(limit: Int, generatedTokens: Int?, reasoningTokens: Int?)
    public var description: String {
        switch self {
        case .invalidConfiguration(let detail): return "AI 配置或输入无效：\(detail)"
        case .missingCredential: return "所选 AI 来源尚未配置 API Key，请在设置中填写。"
        case .transport(let detail): return "AI 请求未完成：\(detail)"
        case .httpStatus(let status): return "AI 服务返回 HTTP \(status)，请检查服务地址、模型、密钥及额度。"
        case .invalidResponse(let detail): return "AI 返回结果无法使用：\(detail)"
        case .invalidEvidence(let detail): return "AI 结果校验失败：\(detail)"
        case .cancelled: return "AI 分析已取消。"
        case .inputTooLarge: return "分析摘要超过 128 KiB，请缩短观察窗口或减少输入。"
        case .generationLengthLimit(let limit, let generated, let reasoning):
            var usage = ""
            if let generated, (0...1_000_000).contains(generated) {
                usage = "；服务报告已生成 \(generated) Token"
                if let reasoning, (0...generated).contains(reasoning) {
                    usage += "（其中推理 \(reasoning) Token）"
                }
            }
            return "AI 因长度限制提前结束，本次输出上限为 \(limit) Token\(usage)。请提高输出上限，或缩短观察窗口后重新预览并分析。"
        }
    }
    public var errorDescription: String? { description }
}
