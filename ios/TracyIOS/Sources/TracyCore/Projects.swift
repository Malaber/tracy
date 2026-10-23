import Foundation

public struct Project: Codable, Equatable, Identifiable, Sendable {
    public var id: Int
    public var name: String
    public var archived: Bool
    public init(id: Int, name: String, archived: Bool = false) {
        self.id = id; self.name = name; self.archived = archived
    }
}

public struct ProjectCatalog: Codable, Sendable {
    public var projects: [Project]
    public var defaultProjectId: Int?
    public init(projects: [Project] = [], defaultProjectId: Int? = nil) {
        self.projects = projects; self.defaultProjectId = defaultProjectId
    }
}

public struct ProjectAllocation: Codable, Equatable, Sendable {
    public var projectId: Int
    public var minutes: Int
    public init(projectId: Int, minutes: Int) { self.projectId = projectId; self.minutes = minutes }
}
