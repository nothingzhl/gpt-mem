import Foundation

/// Bounds the whole transfer as well as inactivity. URLRequest's timeout resets
/// whenever more bytes arrive, so a slowly streaming gateway needs a deadline.
enum AIHTTPResponseReader {
    static func data(for request: URLRequest, session: URLSession,
                     delegate: any URLSessionTaskDelegate, maxBytes: Int,
                     sizeError: String) async throws -> Data {
        try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                let cancellation = HTTPTaskCancellation()
                return try await withTaskCancellationHandler {
                    try Task.checkCancellation()
                    let (bytes, response) = try await session.bytes(for: request, delegate: delegate)
                    cancellation.bind(bytes.task)
                    defer { cancellation.cancel() }
                    try Task.checkCancellation()
                    guard let http = response as? HTTPURLResponse else {
                        throw AIAnalysisError.invalidResponse("服务未返回 HTTP 响应")
                    }
                    guard (200..<300).contains(http.statusCode) else {
                        // Error bodies may echo credentials or submitted facts.
                        throw AIAnalysisError.httpStatus(http.statusCode)
                    }
                    guard response.expectedContentLength <= Int64(maxBytes) else {
                        throw AIAnalysisError.invalidResponse(sizeError)
                    }
                    var data = Data()
                    data.reserveCapacity(min(maxBytes, 16_384))
                    for try await byte in bytes {
                        try Task.checkCancellation()
                        guard data.count < maxBytes else {
                            throw AIAnalysisError.invalidResponse(sizeError)
                        }
                        data.append(byte)
                    }
                    try Task.checkCancellation()
                    return data
                } onCancel: {
                    cancellation.cancel()
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(request.timeoutInterval * 1_000_000_000))
                throw URLError(.timedOut)
            }
            defer { group.cancelAll() }
            guard let data = try await group.next() else { throw CancellationError() }
            return data
        }
    }
}

/// Cancellation can race the arrival of response headers; bind cancels a task
/// immediately if the deadline or caller already cancelled before that point.
private final class HTTPTaskCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionTask?
    private var isCancelled = false

    func bind(_ task: URLSessionTask) {
        lock.lock()
        let alreadyCancelled = isCancelled
        if !alreadyCancelled { self.task = task }
        lock.unlock()
        if alreadyCancelled { task.cancel() }
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        let current = task
        task = nil
        lock.unlock()
        current?.cancel()
    }
}
