import Foundation

nonisolated struct OPDSRequestPolicy: Sendable {
    let access: OPDSCatalogAccess

    func request(
        for url: URL,
        accept: String? = nil
    ) throws -> URLRequest {
        try validateTransport(for: url)
        var request = URLRequest(url: url)
        if let accept {
            request.setValue(accept, forHTTPHeaderField: "Accept")
        }
        applyAuthorization(to: &request)
        return request
    }

    func redirectedRequest(
        from sourceURL: URL,
        proposedRequest: URLRequest
    ) throws -> URLRequest {
        guard let targetURL = proposedRequest.url else {
            throw OPDSServiceError.invalidURL
        }
        if sourceURL.scheme?.lowercased() == "https",
           targetURL.scheme?.lowercased() == "http" {
            throw OPDSServiceError.insecureRedirect
        }
        try validateTransport(for: targetURL)
        var request = proposedRequest
        request.setValue(nil, forHTTPHeaderField: "Authorization")
        applyAuthorization(to: &request)
        return request
    }

    func hasCredentialAccess(to url: URL) -> Bool {
        guard let credentialOrigin = access.credentialOrigin,
              let targetOrigin = OPDSOrigin(url: url) else {
            return false
        }
        return credentialOrigin == targetOrigin
    }

    func validateTransport(for url: URL) throws {
        guard url.isOPDSHTTPURL else {
            throw OPDSServiceError.invalidURL
        }
        guard url.scheme?.lowercased() == "http" else { return }
        guard access.configuration.allowsInsecureHTTP,
              access.configuration.authenticationMode == .none else {
            throw OPDSServiceError.insecureTransport
        }
    }

    private func applyAuthorization(to request: inout URLRequest) {
        guard let url = request.url,
              hasCredentialAccess(to: url),
              let credential = access.credential else {
            return
        }
        let value = Data(
            "\(credential.username):\(credential.password)".utf8
        ).base64EncodedString()
        request.setValue(
            "Basic \(value)",
            forHTTPHeaderField: "Authorization"
        )
    }
}

nonisolated enum BoundedDownload {
    struct Result: Sendable {
        let fileURL: URL
        let response: URLResponse
        let byteCount: Int64
    }

    static func perform(
        using session: URLSession,
        request: URLRequest,
        policy: OPDSRequestPolicy?,
        maximumBytes: Int64
    ) async throws -> Result {
        let maximumBytes = max(1, maximumBytes)
        let delegate = BoundedDownloadDelegate(
            policy: policy,
            maximumBytes: maximumBytes
        )
        let fileURL: URL
        let response: URLResponse
        do {
            (fileURL, response) = try await session.download(
                for: request,
                delegate: delegate
            )
        } catch {
            if let rejection = delegate.rejection { throw rejection }
            if let serviceError = error as? OPDSServiceError {
                throw serviceError
            }
            if error is CancellationError || Task.isCancelled {
                throw CancellationError()
            }
            throw OPDSServiceError.network
        }
        do {
            if let rejection = delegate.rejection { throw rejection }
            try Task.checkCancellation()
            let expectedBytes = response.expectedContentLength
            guard expectedBytes <= 0 || expectedBytes <= maximumBytes else {
                throw OPDSServiceError.downloadTooLarge
            }
            let values = try fileURL.resourceValues(forKeys: [.fileSizeKey])
            guard let fileSize = values.fileSize else {
                throw OPDSServiceError.invalidDownload
            }
            let byteCount = Int64(fileSize)
            guard byteCount <= maximumBytes else {
                throw OPDSServiceError.downloadTooLarge
            }
            return Result(
                fileURL: fileURL,
                response: response,
                byteCount: byteCount
            )
        } catch {
            try? FileManager.default.removeItem(at: fileURL)
            throw error
        }
    }
}

private nonisolated final class BoundedDownloadDelegate:
    OPDSRedirectDelegate,
    URLSessionDownloadDelegate,
    @unchecked Sendable
{
    private let maximumBytes: Int64

    init(
        policy: OPDSRequestPolicy?,
        maximumBytes: Int64
    ) {
        self.maximumBytes = maximumBytes
        super.init(policy: policy)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesWritten <= maximumBytes,
              totalBytesExpectedToWrite <= 0
                || totalBytesExpectedToWrite <= maximumBytes else {
            reject(.downloadTooLarge, cancelling: downloadTask)
            return
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didResumeAtOffset fileOffset: Int64,
        expectedTotalBytes: Int64
    ) {
        guard fileOffset <= maximumBytes,
              expectedTotalBytes <= 0
                || expectedTotalBytes <= maximumBytes else {
            reject(.downloadTooLarge, cancelling: downloadTask)
            return
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        let expectedSize = downloadTask.response?.expectedContentLength ?? -1
        let fileSize = (try? location.resourceValues(
            forKeys: [.fileSizeKey]
        ).fileSize).map(Int64.init) ?? 0
        guard expectedSize <= 0 || expectedSize <= maximumBytes,
              fileSize <= maximumBytes else {
            reject(.downloadTooLarge)
            return
        }
    }
}

nonisolated class OPDSRedirectDelegate:
    NSObject,
    URLSessionTaskDelegate,
    @unchecked Sendable
{
    private let policy: OPDSRequestPolicy?
    private let lock = NSLock()
    private var storedRejection: OPDSServiceError?

    init(policy: OPDSRequestPolicy?) {
        self.policy = policy
    }

    var rejection: OPDSServiceError? {
        lock.withLock { storedRejection }
    }

    fileprivate func reject(
        _ error: OPDSServiceError,
        cancelling task: URLSessionTask? = nil
    ) {
        let shouldCancel = lock.withLock {
            guard storedRejection == nil else { return false }
            storedRejection = error
            return true
        }
        if shouldCancel {
            task?.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        guard let policy else {
            completionHandler(request)
            return
        }
        do {
            completionHandler(try policy.redirectedRequest(
                from: response.url ?? task.currentRequest?.url
                    ?? policy.access.configuration.rootURL,
                proposedRequest: request
            ))
        } catch let error as OPDSServiceError {
            reject(error)
            completionHandler(nil)
        } catch {
            reject(.network)
            completionHandler(nil)
        }
    }
}
