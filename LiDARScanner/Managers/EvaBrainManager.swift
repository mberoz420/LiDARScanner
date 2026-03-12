import Foundation

/// Eva Brain — Central AI Knowledge Base
/// Syncs classification rules, learned parameters, and decisions
/// with the server at scanwizard.robo-wizard.com/api/eva.php
///
/// All systems (Swift app, Ollama, PointCloudLabeler, Claude) share
/// this single knowledge base so Eva's learnings are synchronized.
@MainActor
class EvaBrainManager: ObservableObject {

    static let shared = EvaBrainManager()

    private let brainURL = "https://scanwizard.robo-wizard.com/api/eva.php"
    private let apiKey   = "ScanWizard2025Secret"

    // ── Published state ──
    @Published var isConnected = false
    @Published var lastSyncDate: Date?

    // ── Eva's Knowledge (synced from server) ──
    private(set) var params: [String: Double] = [:]
    private(set) var rules: [[String: String]] = []
    private(set) var learnings: [[String: Any]] = []
    private(set) var identity: [String: String] = [:]

    // ── Classification thresholds derived from Eva's learnings ──
    // These are used by SurfaceClassifier when available
    private(set) var classificationHints: ClassificationHints?

    struct ClassificationHints {
        var ridgePercentile: Double     // density threshold for wall detection
        var cornerAngle: Double         // degrees for corner splitting
        var snapAngle: Double           // degrees for orthogonal snapping
        var minWallLen: Double          // minimum wall length (meters)
        var cellSize: Double            // density grid resolution
    }

    private init() {}

    // MARK: - Sync from Server

    /// Pull Eva's full knowledge base from the server.
    /// Call on app launch and before classification.
    @discardableResult
    func sync() async -> Bool {
        guard let url = URL(string: brainURL) else { return false }
        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        request.timeoutInterval = 10

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                isConnected = false
                return false
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                isConnected = false
                return false
            }

            // Parse knowledge sections
            if let p = json["params"] as? [String: Any] {
                params = p.compactMapValues { ($0 as? NSNumber)?.doubleValue }
                classificationHints = ClassificationHints(
                    ridgePercentile: params["ridgePercentile"] ?? 0.70,
                    cornerAngle: params["cornerAngle"] ?? 25,
                    snapAngle: params["snapAngle"] ?? 10,
                    minWallLen: params["minWallLen"] ?? 0.20,
                    cellSize: params["cellSize"] ?? 0.03
                )
            }

            if let r = json["rules"] as? [[String: String]] {
                rules = r
            }

            if let l = json["learnings"] as? [[String: Any]] {
                learnings = l
            }

            if let id = json["identity"] as? [String: String] {
                identity = id
            }

            isConnected = true
            lastSyncDate = Date()
            debugLog("[Eva Brain] Synced: \(rules.count) rules, \(learnings.count) learnings, params: \(params.count) keys")
            return true

        } catch {
            debugLog("[Eva Brain] Sync failed: \(error.localizedDescription)")
            isConnected = false
            return false
        }
    }

    // MARK: - Push to Server

    /// Log a decision/action to Eva's central brain
    func logDecision(action: String, context: String, reasoning: String) async {
        await push(action: "log", body: [
            "type": "decision",
            "source": "swift_app",
            "log_action": action,
            "context": context,
            "reasoning": reasoning
        ])
    }

    /// Record a scan summary after upload
    func logScanSummary(filename: String, pointCount: Int, project: String?) async {
        await push(action: "scan_summary", body: [
            "filename": filename,
            "point_count": pointCount,
            "actions": ["scan_uploaded"],
            "source": "swift_app",
            "project": project ?? ""
        ] as [String: Any])
    }

    /// Add a new classification rule
    func addRule(id: String, rule: String) async {
        await push(action: "add_rule", body: [
            "id": id,
            "rule": rule,
            "source": "swift_app"
        ])
    }

    // MARK: - Helpers

    /// Get a specific rule by ID
    func getRule(id: String) -> String? {
        return rules.first(where: { $0["id"] == id })?["rule"]
    }

    /// Get all rules as a single string (for context)
    func allRulesText() -> String {
        return rules.compactMap { $0["rule"] }.joined(separator: "\n")
    }

    /// Get the most recent learning analysis
    func latestLearning() -> String? {
        return (learnings.last as? [String: Any])?["analysis"] as? String
    }

    // MARK: - Private

    private func push(action: String, body: [String: Any]) async {
        guard let url = URL(string: "\(brainURL)?action=\(action)") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        request.timeoutInterval = 10

        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }
        request.httpBody = data

        do {
            let (responseData, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode == 200,
               let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any] {
                debugLog("[Eva Brain] \(action): \(json["message"] as? String ?? "ok")")
            }
        } catch {
            debugLog("[Eva Brain] Push \(action) failed: \(error.localizedDescription)")
        }
    }
}

// debugLog is defined in MeshManager.swift — no redeclaration needed
