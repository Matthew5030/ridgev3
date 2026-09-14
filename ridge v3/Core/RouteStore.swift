import Foundation

/// All library IO is isolated from the main actor. A failed read never becomes an empty replacement library.
actor RouteStore {
    private let directory: URL
    private let maximumLibraryBytes = 64 * 1024 * 1024
    private let maximumRoutes = 1_000

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Ridge", isDirectory: true)
            .appendingPathComponent("Routes", isDirectory: true)
    }

    func load() throws -> [RidgeRoute] {
        let url = libraryURL
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber, size.int64Value <= Int64(maximumLibraryBytes) else { throw RouteError.invalidFile("The route library is too large to load safely. Your saved file has been kept.") }
        do {
            let library = try JSONDecoder().decode(Library.self, from: Data(contentsOf: url))
            guard library.version == 1, library.routes.count <= maximumRoutes,
                  Set(library.routes.map(\.id)).count == library.routes.count else { throw RouteError.invalidFile("The route library format is not supported. Your saved file has been kept.") }
            for route in library.routes { try RouteEngine.validate(route) }
            return library.routes.sorted { $0.modifiedAt > $1.modifiedAt }
        } catch let error as RouteError { throw error }
        catch { throw RouteError.invalidFile("The route library could not be read. Your saved file has been kept. \(error.localizedDescription)") }
    }

    func save(_ route: RidgeRoute) throws {
        try RouteEngine.validate(route)
        var routes = try load()
        var updated = route
        updated.modifiedAt = Date()
        if let index = routes.firstIndex(where: { $0.id == route.id }) { routes[index] = updated }
        else {
            guard routes.count < maximumRoutes else { throw RouteError.invalidFile("The route library has reached its 1,000-route limit. Export and remove a route before saving another.") }
            routes.append(updated)
        }
        try persist(routes)
    }

    func delete(id: UUID) throws {
        var routes = try load()
        guard let index = routes.firstIndex(where: { $0.id == id }) else { throw RouteError.missingRoute }
        routes.remove(at: index)
        try persist(routes)
    }

    @discardableResult
    func rename(id: UUID, name: String) throws -> RidgeRoute {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 160 else { throw RouteError.invalidName }
        var routes = try load()
        guard let index = routes.firstIndex(where: { $0.id == id }) else { throw RouteError.missingRoute }
        routes[index].name = name
        routes[index].modifiedAt = Date()
        try persist(routes)
        return routes[index]
    }

    @discardableResult
    func duplicate(id: UUID) throws -> RidgeRoute {
        var routes = try load()
        guard var route = routes.first(where: { $0.id == id }) else { throw RouteError.missingRoute }
        guard routes.count < maximumRoutes else { throw RouteError.invalidFile("The route library has reached its 1,000-route limit.") }
        route.id = UUID()
        route.name = String(route.name.prefix(153)) + " (copy)"
        route.createdAt = Date()
        route.modifiedAt = route.createdAt
        route.waypoints = route.waypoints.map { RouteWaypoint(point: $0.point, name: $0.name) }
        routes.append(route)
        try persist(routes)
        return route
    }

    private var libraryURL: URL { directory.appendingPathComponent("library.json") }
    private struct Library: Codable { var version: Int; var routes: [RidgeRoute] }

    private func persist(_ routes: [RidgeRoute]) throws {
        for route in routes { try RouteEngine.validate(route) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(Library(version: 1, routes: routes))
        guard data.count <= maximumLibraryBytes else { throw RouteError.invalidFile("The route library is full. Export and remove some routes before saving more.") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: libraryURL, options: .atomic)
    }
}
