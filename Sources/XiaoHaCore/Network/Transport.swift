import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct HTTPRequest: Sendable {
    public let method: String
    public let url: String
    public let headers: [String: String]
    public let body: String?
    public let timeout: TimeInterval

    public init(method: String, url: String, headers: [String: String], body: String?, timeout: TimeInterval = 20) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
        self.timeout = timeout
    }
}

public struct HTTPResponse: Sendable {
    public let statusCode: Int
    public let body: String

    public init(statusCode: Int, body: String) {
        self.statusCode = statusCode
        self.body = body
    }
}

/// 网络传输抽象：生产环境走 URLSession，测试注入录制好的响应。
public protocol HTTPTransport: Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}

/// URLSession 实现。iOS 上 URLSession 会自动处理 gzip，无需手动解压。
public final class URLSessionTransport: HTTPTransport, @unchecked Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        guard let url = URL(string: request.url) else {
            throw GwmError.connection("URL 非法：\(request.url)")
        }
        var urlRequest = URLRequest(url: url, timeoutInterval: request.timeout)
        urlRequest.httpMethod = request.method
        for (key, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }
        if let body = request.body {
            urlRequest.httpBody = Data(body.utf8)
        }
        do {
            let (data, response) = try await session.data(for: urlRequest)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            return HTTPResponse(statusCode: code, body: String(decoding: data, as: UTF8.self))
        } catch let error as URLError {
            switch error.code {
            case .timedOut:
                throw GwmError.connection("连接超时，请稍后重试")
            case .cannotFindHost, .cannotConnectToHost, .notConnectedToInternet, .networkConnectionLost:
                throw GwmError.connection("无法连接服务器，请检查网络")
            default:
                throw GwmError.connection(error.localizedDescription)
            }
        }
    }
}
