import Foundation

public extension UploadSettings {
    /// Replace the destination sharing `destination.id`, or append it if new.
    func addingOrUpdating(_ destination: UploadDestination) -> UploadSettings {
        var copy = self
        if let idx = copy.destinations.firstIndex(where: { $0.id == destination.id }) {
            copy.destinations[idx] = destination
        } else {
            copy.destinations.append(destination)
        }
        return copy
    }

    /// Remove a destination by id; clears the active selection if it pointed there.
    func removing(id: String) -> UploadSettings {
        var copy = self
        copy.destinations.removeAll { $0.id == id }
        if copy.activeDestinationID == id { copy.activeDestinationID = nil }
        return copy
    }

    /// Set (or clear, with `nil`) the active destination.
    func settingActive(id: String?) -> UploadSettings {
        var copy = self
        copy.activeDestinationID = id
        return copy
    }
}
