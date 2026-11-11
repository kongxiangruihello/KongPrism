import Foundation
import CryptoKit

/// HTTP helpers. Every session sets its proxy explicitly, so requests never loop
/// through the system proxy that KongPrism itself controls.
enum Net {
    enum Route {
        case direct
        case viaProxy(port: Int)
        /// Whatever the system proxy currently is (another client such as KongBabel).
        case system

        var label: String {
            switch self {
            case .direct: return "直连"
            case .viaProxy(let port): return "经代理 127.0.0.1:\(port)"
            case .system: return "经系统代理"
            }
        }
    }

    struct HTTPError: LocalizedError {
        let status: Int
        let url: URL
        var errorDescription: String? { "服务器返回 HTTP \(status)（\(url.host ?? url.absoluteString)）" }
    }

    static func configuration(_ route: Route, timeout: TimeInterval) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = max(timeout, 600)
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        switch route {
        case .direct:
            configuration.connectionProxyDictionary = [
                kCFNetworkProxiesHTTPEnable as String: 0,
                kCFNetworkProxiesHTTPSEnable as String: 0,
                kCFNetworkProxiesSOCKSEnable as String: 0,
                kCFNetworkProxiesProxyAutoConfigEnable as String: 0,
            ]
        case .system:
            configuration.connectionProxyDictionary = nil
        case .viaProxy(let port):
            configuration.connectionProxyDictionary = [
                kCFNetworkProxiesHTTPEnable as String: 1,
                kCFNetworkProxiesHTTPProxy as String: "127.0.0.1",
                kCFNetworkProxiesHTTPPort as String: port,
                kCFNetworkProxiesHTTPSEnable as String: 1,
                kCFNetworkProxiesHTTPSProxy as String: "127.0.0.1",
                kCFNetworkProxiesHTTPSPort as String: port,
            ]
        }
        return configuration
    }

    static func session(_ route: Route, timeout: TimeInterval = 20, delegate: URLSessionDelegate? = nil) -> URLSession {
        URLSession(configuration: configuration(route, timeout: timeout), delegate: delegate, delegateQueue: nil)
    }

    /// GET with each route in turn until one answers 2xx.
    static func get(_ url: URL, headers: [String: String] = [:], routes: [Route], timeout: TimeInterval = 20) async throws -> (Data, HTTPURLResponse) {
        var lastError: Error = URLError(.notConnectedToInternet)
        for route in routes {
            var request = URLRequest(url: url)
            for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
            let session = session(route, timeout: timeout)
            defer { session.finishTasksAndInvalidate() }
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
                guard (200..<300).contains(http.statusCode) else { throw HTTPError(status: http.statusCode, url: url) }
                return (data, http)
            } catch {
                AppLog.write("请求失败（\(route.label)）\(url.host ?? ""): \(error.localizedDescription)")
                lastError = error
            }
        }
        throw lastError
    }

    /// Downloads to a temporary file, reporting progress (0…1), trying each route in turn.
    static func download(_ url: URL, headers: [String: String] = [:], routes: [Route],
                         progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        var lastError: Error = URLError(.notConnectedToInternet)
        for route in routes {
            var request = URLRequest(url: url)
            for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
            do {
                return try await DownloadTask(request: request, route: route, progress: progress).run()
            } catch {
                AppLog.write("下载失败（\(route.label)）\(url.lastPathComponent): \(error.localizedDescription)")
                lastError = error
            }
        }
        throw lastError
    }

    /// The `Location` of a redirect, without following it (GitHub's /releases/latest → /releases/tag/vX).
    static func redirectLocation(_ url: URL, routes: [Route]) async throws -> String {
        var lastError: Error = URLError(.cannotFindHost)
        for route in routes {
            let blocker = RedirectBlocker()
            let session = session(route, timeout: 15, delegate: blocker)
            defer { session.finishTasksAndInvalidate() }
            do {
                var request = URLRequest(url: url)
                request.httpMethod = "HEAD"
                let (_, response) = try await session.data(for: request)
                if let http = response as? HTTPURLResponse, let location = http.value(forHTTPHeaderField: "Location") {
                    return location
                }
                if let final = response.url?.absoluteString, final.contains("/releases/tag/") { return final }
                throw URLError(.badServerResponse)
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

private final class RedirectBlocker: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// One download with progress, as async/await.
private final class DownloadTask: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let request: URLRequest
    private let route: Net.Route
    private let progress: @Sendable (Double) -> Void
    private var continuation: CheckedContinuation<URL, Error>?
    private var session: URLSession?

    init(request: URLRequest, route: Net.Route, progress: @escaping @Sendable (Double) -> Void) {
        self.request = request
        self.route = route
        self.progress = progress
    }

    func run() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let session = URLSession(configuration: Net.configuration(route, timeout: 30), delegate: self, delegateQueue: nil)
            self.session = session
            session.downloadTask(with: request).resume()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        progress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            finish(.failure(Net.HTTPError(status: http.statusCode, url: request.url!)))
            return
        }
        // The file at `location` is deleted when this method returns.
        let kept = Paths.updates.appendingPathComponent(UUID().uuidString + "-" + (request.url?.lastPathComponent ?? "download"))
        do {
            try FileManager.default.moveItem(at: location, to: kept)
            finish(.success(kept))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)) }
    }

    private func finish(_ result: Result<URL, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        session?.finishTasksAndInvalidate()
        continuation.resume(with: result)
    }
}

/// Runs command-line tools.
enum Shell {
    struct Result {
        let status: Int32
        let output: String
        var ok: Bool { status == 0 }
    }

    @discardableResult
    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 60) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return Result(status: -1, output: error.localizedDescription) }
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        return Result(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }

    /// Runs the closure off the main thread.
    static func background<T>(_ work: @escaping () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: work()) }
        }
    }

    static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }
}
