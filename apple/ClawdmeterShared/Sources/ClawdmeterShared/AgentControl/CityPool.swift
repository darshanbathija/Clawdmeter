import Foundation

/// City-name pool for session display labels. Conductor uses cities as
/// memorable, scannable labels on small screens (Tokyo, Lima, Berlin).
/// We keep goal-derived slugs for git branches and worktree dirs (better
/// for code provenance), and use city names only as the *display* label
/// on iOS sidebar, Watch complication, and Live Activity.
///
/// Sessions v2 Phase 9 / T19. Caller hashes `session.id` (or another
/// stable string) to pick a city; collisions get a `-2` / `-3` suffix.
public enum CityPool {

    /// ~200 globally-recognizable cities. Mix of capitals + major cities
    /// across continents so the labels feel international, not US-centric.
    public static let cities: [String] = [
        "Tokyo", "Osaka", "Kyoto", "Sapporo", "Seoul", "Busan", "Beijing", "Shanghai",
        "Hong Kong", "Taipei", "Singapore", "Bangkok", "Hanoi", "Manila", "Jakarta",
        "Mumbai", "Delhi", "Bangalore", "Karachi", "Lahore", "Dhaka", "Colombo",
        "Tehran", "Dubai", "Doha", "Riyadh", "Kuwait", "Jerusalem", "Istanbul",
        "Athens", "Rome", "Milan", "Venice", "Florence", "Naples", "Madrid", "Barcelona",
        "Lisbon", "Porto", "Paris", "Lyon", "Marseille", "Nice", "Brussels", "Antwerp",
        "Amsterdam", "Rotterdam", "Berlin", "Hamburg", "Munich", "Cologne", "Frankfurt",
        "Vienna", "Salzburg", "Prague", "Budapest", "Warsaw", "Krakow", "Helsinki",
        "Stockholm", "Oslo", "Bergen", "Copenhagen", "Aarhus", "Reykjavik", "Dublin",
        "Cork", "Edinburgh", "Glasgow", "London", "Manchester", "Bristol", "Cardiff",
        "Zurich", "Geneva", "Bern", "Lucerne", "Moscow", "Kiev", "Minsk", "Tbilisi",
        "Cairo", "Alexandria", "Tunis", "Casablanca", "Marrakech", "Lagos", "Nairobi",
        "Cape Town", "Johannesburg", "Addis Ababa", "Dakar", "Accra", "Algiers",
        "Auckland", "Wellington", "Sydney", "Melbourne", "Brisbane", "Perth", "Hobart",
        "Honolulu", "Anchorage", "Vancouver", "Seattle", "Portland", "San Francisco",
        "Oakland", "Berkeley", "Sacramento", "Los Angeles", "San Diego", "Las Vegas",
        "Phoenix", "Tucson", "Denver", "Salt Lake City", "Boise", "Minneapolis",
        "Chicago", "Detroit", "Milwaukee", "Madison", "Cleveland", "Pittsburgh",
        "Cincinnati", "Columbus", "Indianapolis", "Louisville", "Nashville", "Memphis",
        "Atlanta", "Charlotte", "Raleigh", "Richmond", "Baltimore", "Washington",
        "Philadelphia", "New York", "Brooklyn", "Boston", "Providence", "Portland",
        "Montreal", "Toronto", "Ottawa", "Quebec", "Halifax", "Calgary", "Edmonton",
        "Winnipeg", "Mexico City", "Guadalajara", "Monterrey", "Cancun", "Tijuana",
        "Havana", "San Juan", "Santo Domingo", "Kingston", "Panama", "San Jose",
        "Guatemala City", "Tegucigalpa", "Managua", "Lima", "Cusco", "La Paz",
        "Quito", "Bogota", "Medellin", "Caracas", "Georgetown", "Paramaribo",
        "Cayenne", "Brasilia", "Sao Paulo", "Rio", "Salvador", "Recife", "Manaus",
        "Buenos Aires", "Cordoba", "Mendoza", "Montevideo", "Asuncion", "Santiago",
        "Valparaiso",
    ]

    /// Pick a city for a session deterministically. Same id → same city
    /// across launches (so the sidebar label is stable).
    public static func cityName(for sessionId: UUID) -> String {
        let raw = abs(sessionId.uuidString.hashValue)
        let index = raw % cities.count
        return cities[index]
    }

    /// Pick a city that doesn't collide with the existing assigned cities.
    /// Returns the base city; caller appends `-2`, `-3` if needed.
    public static func uniqueCityName(for sessionId: UUID, taken: Set<String>) -> String {
        let base = cityName(for: sessionId)
        if !taken.contains(base) { return base }
        for n in 2...100 {
            let candidate = "\(base)-\(n)"
            if !taken.contains(candidate) { return candidate }
        }
        // Fallback to UUID prefix when pool exhausted (shouldn't happen with 200+).
        return "Session-\(sessionId.uuidString.prefix(6))"
    }
}
