import XCTest
import Darwin
@testable import BusinessBarCore

final class RemoteModelCatalogTests: XCTestCase {

    // MARK: - parse

    func testParseRejectsUnexpectedShape() {
        XCTAssertNil(RemoteModelCatalog.parse(data: Data("{\"models\":[]}".utf8)))
        XCTAssertNil(RemoteModelCatalog.parse(data: Data("not json at all".utf8)))
        XCTAssertNil(RemoteModelCatalog.parse(data: Data("{\"data\":\"nope\"}".utf8)))
    }

    func testParseDropsRowsWithoutID() {
        let payload = """
        {"data":[{"id":"m1"},{"id":""},{"supported_parameters":["reasoning_effort"]}]}
        """
        let models = RemoteModelCatalog.parse(data: Data(payload.utf8))
        XCTAssertEqual(models?.map(\.id), ["m1"])
    }

    // MARK: - fetch against a real local HTTP server

    /// One-connection-at-a-time HTTP server on 127.0.0.1, ephemeral
    /// port, serving the same status and body to every request until
    /// stop(). Records the Authorization header of the last request.
    private final class MockModelsServer {
        private let fd: Int32
        private(set) var port: UInt16 = 0
        private let lock = NSLock()
        private var stopped = false
        private var lastAuthValue: String?

        private let statusLine: String
        private let body: Data

        init(statusLine: String, body: Data) throws {
            self.statusLine = statusLine
            self.body = body

            fd = socket(AF_INET, SOCK_STREAM, 0)
            if fd < 0 { throw NSError(domain: "MockModelsServer", code: Int(errno)) }

            var one: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))

            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = 0
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")

            let bindResult = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if bindResult != 0 {
                close(fd)
                throw NSError(domain: "MockModelsServer", code: Int(errno))
            }

            var bound = sockaddr_in()
            var boundLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            withUnsafeMutablePointer(to: &bound) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    getsockname(fd, $0, &boundLen)
                }
            }
            port = UInt16(bigEndian: bound.sin_port)

            listen(fd, 16)
        }

        func authorizationHeader() -> String? {
            lock.lock()
            defer { lock.unlock() }
            return lastAuthValue
        }

        func start() {
            let thread = Thread { [weak self] in self?.serve() }
            thread.name = "MockModelsServer"
            thread.start()
        }

        func stop() {
            lock.lock()
            stopped = true
            lock.unlock()
            close(fd)
        }

        private func serve() {
            while true {
                lock.lock()
                let halted = stopped
                lock.unlock()
                if halted { break }

                var clientAddr = sockaddr()
                var clientLen = socklen_t(MemoryLayout<sockaddr>.size)
                let client = accept(fd, &clientAddr, &clientLen)
                if client < 0 { break }
                handle(client)
                close(client)
            }
        }

        private func handle(_ client: Int32) {
            var requestBytes: [UInt8] = []
            var chunk = [UInt8](repeating: 0, count: 4096)
            while !requestBytes.suffix(4).elementsEqual([13, 10, 13, 10]) {
                let received = recv(client, &chunk, chunk.count, 0)
                if received <= 0 { break }
                requestBytes.append(contentsOf: chunk[0..<received])
                if requestBytes.count > 65_536 { break }
            }

            let request = String(decoding: requestBytes, as: UTF8.self)
            let authLine = request.components(separatedBy: "\r\n").first {
                $0.lowercased().hasPrefix("authorization:")
            }
            lock.lock()
            lastAuthValue = authLine.map {
                String($0.dropFirst("authorization:".count).trimmingCharacters(in: .whitespaces))
            }
            lock.unlock()

            var response = Data(statusLine.utf8)
            response += Data("\r\nContent-Type: application/json\r\n".utf8)
            response += Data("Content-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
            response += body
            response.withUnsafeBytes { raw in
                _ = send(client, raw.baseAddress, raw.count, 0)
            }
            shutdown(client, Int32(SHUT_WR))
        }
    }

    private func makeServer(status: String = "HTTP/1.1 200 OK", body: String) throws -> MockModelsServer {
        try MockModelsServer(statusLine: status, body: Data(body.utf8))
    }

    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 10
        return URLSession(configuration: config)
    }

    func testFetchParsesOpenRouterStylePayload() async throws {
        let payload = """
        {"data":[
          {"id":"openai/gpt-5","supported_parameters":["tools","reasoning_effort"]},
          {"id":"anthropic/claude-haiku","supported_parameters":["tools"]},
          {"id":"x-ai/grok-reasoning","reasoning":true},
          {"id":""}
        ]}
        """
        let server = try makeServer(body: payload)
        server.start()
        defer { server.stop() }

        let models = try await RemoteModelCatalog.fetch(
            baseURL: "http://127.0.0.1:\(server.port)/v1",
            apiKey: "",
            session: makeSession()
        )

        XCTAssertEqual(models.count, 3)

        let gpt = try XCTUnwrap(models.first { $0.id == "openai/gpt-5" })
        XCTAssertTrue(gpt.supportsReasoning)
        XCTAssertEqual(gpt.effortOptions, EffortVocabulary.defaultLevels.filter { $0 != "none" })

        let haiku = try XCTUnwrap(models.first { $0.id == "anthropic/claude-haiku" })
        XCTAssertFalse(haiku.supportsReasoning)
        XCTAssertNil(haiku.effortOptions)

        let grok = try XCTUnwrap(models.first { $0.id == "x-ai/grok-reasoning" })
        XCTAssertTrue(grok.supportsReasoning)
        XCTAssertNil(grok.effortOptions)
    }

    func testFetchNormalizesTrailingSlashAndSendsAuthHeader() async throws {
        let server = try makeServer(body: "{\"data\":[]}")
        server.start()
        defer { server.stop() }

        let session = makeSession()
        let withKey = try await RemoteModelCatalog.fetch(
            baseURL: "http://127.0.0.1:\(server.port)/v1/",
            apiKey: "sk-test-123",
            session: session
        )
        XCTAssertEqual(withKey, [])
        XCTAssertEqual(server.authorizationHeader(), "Bearer sk-test-123")

        let withoutKey = try await RemoteModelCatalog.fetch(
            baseURL: "http://127.0.0.1:\(server.port)",
            apiKey: "",
            session: session
        )
        XCTAssertEqual(withoutKey, [])
        XCTAssertNil(server.authorizationHeader())
    }

    func testFetchThrowsOnHTTPErrorStatus() async throws {
        let server = try makeServer(status: "HTTP/1.1 500 Internal Server Error", body: "{\"error\":\"boom\"}")
        server.start()
        defer { server.stop() }

        do {
            _ = try await RemoteModelCatalog.fetch(
                baseURL: "http://127.0.0.1:\(server.port)",
                apiKey: "",
                session: makeSession()
            )
            XCTFail("expected badServerResponse")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .badServerResponse)
        }
    }

    func testFetchReturnsEmptyOnMalformedBody() async throws {
        let server = try makeServer(body: "this is not json")
        server.start()
        defer { server.stop() }

        let models = try await RemoteModelCatalog.fetch(
            baseURL: "http://127.0.0.1:\(server.port)",
            apiKey: "",
            session: makeSession()
        )
        XCTAssertEqual(models, [])
    }

    func testFetchThrowsOnInvalidBaseURL() async {
        do {
            _ = try await RemoteModelCatalog.fetch(
                baseURL: "not a url",
                apiKey: "",
                session: makeSession()
            )
            XCTFail("expected a thrown URLError")
        } catch let error as URLError {
            // New Foundation renumbered URLError codes and its parser is
            // lenient enough to build a request for junk input, so the
            // error can come from our guard or from URLSession. Either
            // way it must be a URLError, not a crash or a bogus list.
            XCTAssertTrue([URLError.Code.badURL, .unsupportedURL, .badServerResponse].contains(error.code))
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }
}