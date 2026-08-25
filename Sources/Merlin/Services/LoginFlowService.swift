import Foundation

/// Implements Nextcloud Login Flow v2.
///
/// Usage:
/// 1. Call `start(serverUrl:)` → returns a login URL to open in Safari
/// 2. Call `pollForCredentials()` → polls until the user finishes auth in the browser
/// 3. On success, `username` and `appPassword` are stored in `CredentialsStore`
@MainActor
final class LoginFlowService: ObservableObject {

    enum LoginFlowError: LocalizedError {
        case invalidServerUrl
        case serverError(String)
        case timeout
        case cancelled

        var errorDescription: String? {
            switch self {
            case .invalidServerUrl: return "Invalid server URL"
            case .serverError(let msg): return msg
            case .timeout: return "Login timed out. Please try again."
            case .cancelled: return "Login was cancelled."
            }
        }
    }

    @Published var isLoading = false
    @Published var loginURL: URL? = nil

    private var pollToken: String? = nil
    private var pollEndpoint: URL? = nil
    private var pollTask: Task<Void, Never>? = nil

    // MARK: – Step 1: Initiate Login Flow

    /// POST to /index.php/login/v2 → returns URL to open in browser
    func start(serverUrl: String) async throws -> URL {
        isLoading = true
        defer { isLoading = false }

        let base = serverUrl
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/$", with: "", options: .regularExpression)

        // merlin-server bildet Nextclouds Login-Flow-v2-JSON identisch nach
        // (siehe merlin-server/src/Controller/LoginFlowController.php) - nur
        // die Start-URL unterscheidet sich, Polling/Parsing bleibt unverändert.
        let path = CredentialsStore.shared.backendKind == .standalone ? "/login/v2" : "/index.php/login/v2"
        guard let url = URL(string: "\(base)\(path)") else {
            throw LoginFlowError.invalidServerUrl
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // Content-Length: 0 for empty POST body
        request.httpBody = Data()

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw LoginFlowError.serverError("Server returned HTTP \(statusCode)")
        }

        struct InitResponse: Decodable {
            struct Poll: Decodable {
                let token: String
                let endpoint: String
            }
            let poll: Poll
            let login: String
        }

        let decoded = try JSONDecoder().decode(InitResponse.self, from: data)

        guard let loginUrl = URL(string: decoded.login),
              let endpointUrl = URL(string: decoded.poll.endpoint) else {
            throw LoginFlowError.serverError("Invalid URLs in server response")
        }

        self.pollToken = decoded.poll.token
        self.pollEndpoint = endpointUrl
        self.loginURL = loginUrl
        return loginUrl
    }

    // MARK: – Step 2: Poll for credentials

    /// Polls the endpoint every 5 seconds until the user completes login.
    /// On success, writes credentials to CredentialsStore.
    /// Throws `LoginFlowError.timeout` after 5 minutes.
    func pollForCredentials() async throws {
        guard let token = pollToken, let endpoint = pollEndpoint else {
            throw LoginFlowError.serverError("Login flow not started")
        }

        let deadline = Date().addingTimeInterval(5 * 60) // 5-minute timeout
        let interval: TimeInterval = 5

        while Date() < deadline {
            try Task.checkCancellation()

            if let result = try await attemptPoll(endpoint: endpoint, token: token) {
                CredentialsStore.shared.nextcloudUrl = result.server
                CredentialsStore.shared.username     = result.loginName
                CredentialsStore.shared.appPassword  = result.appPassword
                loginURL = nil
                return
            }

            try await Task.sleep(for: .seconds(interval))
        }

        throw LoginFlowError.timeout
    }

    /// Returns credentials on success, nil if still waiting, throws on error.
    private func attemptPoll(endpoint: URL, token: String) async throws -> PollResult? {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = "token=\(token)".data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else { return nil }

        // 404 = still waiting
        if http.statusCode == 404 { return nil }

        guard http.statusCode == 200 else {
            throw LoginFlowError.serverError("Poll failed with HTTP \(http.statusCode)")
        }

        return try JSONDecoder().decode(PollResult.self, from: data)
    }

    func cancel() {
        pollTask?.cancel()
        pollTask = nil
        pollToken = nil
        pollEndpoint = nil
        loginURL = nil
    }
}

private struct PollResult: Decodable {
    let server: String
    let loginName: String
    let appPassword: String
}
