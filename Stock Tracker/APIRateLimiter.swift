//
//  APIRateLimiter.swift
//  Stock Tracker
//
//  Client-side rate limiting with exponential backoff, 429 handling,
//  and per-endpoint throttling.
//

import Foundation

// MARK: - Rate Limiter

actor APIRateLimiter {
    static let shared = APIRateLimiter()

    // MARK: - Configuration

    struct EndpointConfig {
        let maxRequestsPerMinute: Int
        let maxRequestsPerHour: Int
        let baseRetryDelay: TimeInterval      // seconds
        let maxRetryDelay: TimeInterval        // seconds
        let maxRetries: Int

        static let `default` = EndpointConfig(
            maxRequestsPerMinute: 30,
            maxRequestsPerHour: 500,
            baseRetryDelay: 1.0,
            maxRetryDelay: 60.0,
            maxRetries: 3
        )

        static let alpaca = EndpointConfig(
            maxRequestsPerMinute: 200,
            maxRequestsPerHour: 1000,
            baseRetryDelay: 1.0,
            maxRetryDelay: 30.0,
            maxRetries: 3
        )

        static let coinGecko = EndpointConfig(
            maxRequestsPerMinute: 10,
            maxRequestsPerHour: 100,
            baseRetryDelay: 2.0,
            maxRetryDelay: 120.0,
            maxRetries: 2
        )

        static let newsAPI = EndpointConfig(  // now used for Finnhub
            maxRequestsPerMinute: 60,
            maxRequestsPerHour: 3_600,
            baseRetryDelay: 1.0,
            maxRetryDelay: 30.0,
            maxRetries: 2
        )

        static let alphaVantage = EndpointConfig(
            maxRequestsPerMinute: 5,
            maxRequestsPerHour: 75,
            baseRetryDelay: 12.0,
            maxRetryDelay: 60.0,
            maxRetries: 2
        )

        static let openAI = EndpointConfig(
            maxRequestsPerMinute: 10,
            maxRequestsPerHour: 100,
            baseRetryDelay: 2.0,
            maxRetryDelay: 30.0,
            maxRetries: 0
        )

        static let gemini = EndpointConfig(
            maxRequestsPerMinute: 10,
            maxRequestsPerHour: 100,
            baseRetryDelay: 2.0,
            maxRetryDelay: 30.0,
            maxRetries: 0
        )

        static let snapTrade = EndpointConfig(
            maxRequestsPerMinute: 30,
            maxRequestsPerHour: 300,
            baseRetryDelay: 2.0,
            maxRetryDelay: 60.0,
            maxRetries: 3
        )

        static let fiscalAI = EndpointConfig(
            maxRequestsPerMinute: 10,   // Conservative to stay within 250/day
            maxRequestsPerHour: 50,
            baseRetryDelay: 2.0,
            maxRetryDelay: 60.0,
            maxRetries: 2
        )

        static let yahoo = EndpointConfig(
            maxRequestsPerMinute: 60,
            maxRequestsPerHour: 1000,
            baseRetryDelay: 1.0,
            maxRetryDelay: 30.0,
            maxRetries: 2
        )
    }

    // MARK: - State

    private var requestTimestamps: [String: [Date]] = [:]
    private var retryAfterDates: [String: Date] = [:]

    private init() {}

    // MARK: - Throttle Check

    /// Check if a request to the given endpoint is allowed.
    /// Returns nil if allowed, or a TimeInterval to wait if throttled.
    func throttleDelay(for endpoint: String, config: EndpointConfig = .default) -> TimeInterval? {
        let now = Date()

        // Check if we're in a server-mandated retry-after period
        if let retryAfter = retryAfterDates[endpoint], now < retryAfter {
            return retryAfter.timeIntervalSince(now)
        }

        // Clean old timestamps
        cleanTimestamps(for: endpoint, before: now.addingTimeInterval(-3600))

        let timestamps = requestTimestamps[endpoint] ?? []

        // Check per-minute limit
        let oneMinuteAgo = now.addingTimeInterval(-60)
        let recentMinuteCount = timestamps.filter { $0 > oneMinuteAgo }.count
        if recentMinuteCount >= config.maxRequestsPerMinute {
            let oldestInWindow = timestamps.filter { $0 > oneMinuteAgo }.min() ?? now
            return 60.0 - now.timeIntervalSince(oldestInWindow) + 0.5
        }

        // Check per-hour limit
        let oneHourAgo = now.addingTimeInterval(-3600)
        let recentHourCount = timestamps.filter { $0 > oneHourAgo }.count
        if recentHourCount >= config.maxRequestsPerHour {
            let oldestInWindow = timestamps.filter { $0 > oneHourAgo }.min() ?? now
            return 3600.0 - now.timeIntervalSince(oldestInWindow) + 0.5
        }

        return nil
    }

    /// Record that a request was made to the given endpoint.
    func recordRequest(for endpoint: String) {
        var timestamps = requestTimestamps[endpoint] ?? []
        timestamps.append(Date())
        requestTimestamps[endpoint] = timestamps
    }

    /// Record a server-mandated retry-after delay (from 429 response).
    func recordRetryAfter(for endpoint: String, delay: TimeInterval) {
        retryAfterDates[endpoint] = Date().addingTimeInterval(delay)
    }

    /// Calculate exponential backoff delay for a given retry attempt.
    func backoffDelay(attempt: Int, config: EndpointConfig = .default) -> TimeInterval {
        let delay = config.baseRetryDelay * pow(2.0, Double(attempt))
        let jitter = Double.random(in: 0...0.5) * delay // Add jitter to prevent thundering herd
        return min(delay + jitter, config.maxRetryDelay)
    }

    // MARK: - Cleanup

    private func cleanTimestamps(for endpoint: String, before cutoff: Date) {
        requestTimestamps[endpoint]?.removeAll { $0 < cutoff }
    }

    /// Reset all rate limiting state (e.g., for testing)
    func reset() {
        requestTimestamps.removeAll()
        retryAfterDates.removeAll()
    }
}

// MARK: - Rate-Limited URLSession Extension

extension URLSession {

    /// Perform a request with rate limiting, exponential backoff, and 429 handling.
    func rateLimitedData(
        for request: URLRequest,
        endpoint: String,
        config: APIRateLimiter.EndpointConfig = .default
    ) async throws -> (Data, URLResponse) {
        let limiter = APIRateLimiter.shared

        for attempt in 0...config.maxRetries {
            // Check throttle
            if let delay = await limiter.throttleDelay(for: endpoint, config: config) {
                SecureLogger.info("Rate limited for \(endpoint): waiting \(String(format: "%.1f", delay))s")
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }

            // Record the request
            await limiter.recordRequest(for: endpoint)

            do {
                let (data, response) = try await self.data(for: request)

                guard let httpResponse = response as? HTTPURLResponse else {
                    return (data, response)
                }

                switch httpResponse.statusCode {
                case 200...299:
                    return (data, response)

                case 429:
                    // Rate limited by server — log the response body for diagnostics
                    let body429 = String(data: data, encoding: .utf8) ?? ""
                    let fallbackDelay = await limiter.backoffDelay(attempt: attempt, config: config)
                    let retryAfter = parseRetryAfter(from: httpResponse) ?? fallbackDelay
                    await limiter.recordRetryAfter(for: endpoint, delay: retryAfter)

                    SecureLogger.warning("429 for \(endpoint): \(body429.prefix(300)) — wait \(String(format: "%.1f", retryAfter))s (attempt \(attempt + 1)/\(config.maxRetries + 1))")

                    if attempt < config.maxRetries {
                        try await Task.sleep(nanoseconds: UInt64(retryAfter * 1_000_000_000))
                        continue
                    }
                    // Max retries exceeded
                    throw RateLimitError.tooManyRequests(retryAfter: retryAfter)

                case 500...599:
                    // Server error - retry with backoff
                    if attempt < config.maxRetries {
                        let delay = await limiter.backoffDelay(attempt: attempt, config: config)
                        SecureLogger.warning("Server error \(httpResponse.statusCode) for \(endpoint). Retry in \(String(format: "%.1f", delay))s")
                        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                        continue
                    }
                    return (data, response) // Return the error response after max retries

                default:
                    return (data, response)
                }
            } catch let error as RateLimitError {
                throw error
            } catch {
                // Network error - retry with backoff
                if attempt < config.maxRetries {
                    let delay = await limiter.backoffDelay(attempt: attempt, config: config)
                    SecureLogger.warning("Network error for \(endpoint): \(error.localizedDescription). Retry in \(String(format: "%.1f", delay))s")
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    continue
                }
                throw error
            }
        }

        throw RateLimitError.maxRetriesExceeded
    }

    /// Parse Retry-After header (seconds or HTTP date)
    private func parseRetryAfter(from response: HTTPURLResponse) -> TimeInterval? {
        guard let retryAfterHeader = response.value(forHTTPHeaderField: "Retry-After") else {
            return nil
        }

        // Try as seconds
        if let seconds = Double(retryAfterHeader) {
            return seconds
        }

        // Try as HTTP date
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        if let date = formatter.date(from: retryAfterHeader) {
            return max(0, date.timeIntervalSinceNow)
        }

        return nil
    }
}

// MARK: - Rate Limit Errors

enum RateLimitError: LocalizedError {
    case tooManyRequests(retryAfter: TimeInterval)
    case maxRetriesExceeded
    case throttled(waitTime: TimeInterval)

    var errorDescription: String? {
        switch self {
        case .tooManyRequests(let retryAfter):
            return "Rate limit exceeded. Please wait \(Int(retryAfter)) seconds."
        case .maxRetriesExceeded:
            return "Maximum retry attempts exceeded. Please try again later."
        case .throttled(let waitTime):
            return "Request throttled. Please wait \(Int(waitTime)) seconds."
        }
    }
}

// MARK: - Secure URLSession Configuration

enum SecureURLSessionFactory {

    /// Create a URLSession with security-hardened configuration
    static func makeSecureSession(
        timeoutInterval: TimeInterval = 30,
        delegate: URLSessionDelegate? = nil
    ) -> URLSession {
        let config = URLSessionConfiguration.default

        // Timeouts
        config.timeoutIntervalForRequest = timeoutInterval
        config.timeoutIntervalForResource = timeoutInterval * 3

        // Security
        config.tlsMinimumSupportedProtocolVersion = .TLSv12
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.urlCache = nil // Don't cache sensitive financial data
        config.requestCachePolicy = .reloadIgnoringLocalCacheData

        // Prevent background network activity logging
        config.httpAdditionalHeaders = [
            "Accept": "application/json",
            "Accept-Encoding": "gzip, deflate, br"
        ]

        // Disable waiting for connectivity to fail fast
        config.waitsForConnectivity = false

        return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }
}
