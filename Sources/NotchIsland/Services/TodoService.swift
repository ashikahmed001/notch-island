import Foundation
import Combine

/// The Home tab's to-do list, kept on this Mac.
final class TodoService: ObservableObject {
    struct Todo: Identifiable, Codable, Equatable {
        var id = UUID()
        var title: String
        var isDone = false
    }

    @Published private(set) var items: [Todo] = []
    private static let key = "home.todos"

    var openCount: Int { items.filter { !$0.isDone }.count }

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode([Todo].self, from: data) {
            items = saved
        }
    }

    func add(_ title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        items.append(Todo(title: String(trimmed.prefix(120))))
        save()
    }

    func toggle(_ todo: Todo) {
        guard let index = items.firstIndex(where: { $0.id == todo.id }) else { return }
        items[index].isDone.toggle()
        save()
    }

    func remove(_ todo: Todo) {
        items.removeAll { $0.id == todo.id }
        save()
    }

    func clearDone() {
        items.removeAll(where: \.isDone)
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}
