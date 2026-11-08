import Foundation

@MainActor
final class WorkoutStore: ObservableObject {
    @Published private(set) var sessions: [WorkoutSession] = []
    private let key = "smartbell.sessions.v1"

    init() { load() }

    func save(_ session: WorkoutSession) {
        sessions.insert(session, at: 0)
        if let data = try? JSONEncoder().encode(sessions) { UserDefaults.standard.set(data, forKey: key) }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([WorkoutSession].self, from: data) else { return }
        sessions = decoded
    }
}
