import Foundation

public enum ZoneMethod: String, CaseIterable, Codable, Sendable {
    /// Karvonen / Heart Rate Reserve: RHR + intensity × (MaxHR − RHR).
    case karvonen
    /// Straight percentage of Max HR: intensity × MaxHR.
    case percentMaxHR

    public var displayName: String {
        switch self {
        case .karvonen: "Karvonen (HRR)"
        case .percentMaxHR: "% Max HR"
        }
    }
}

public struct ZoneConfiguration: Codable, Sendable, Equatable {
    public var method: ZoneMethod
    /// Lower bound of Zone 1–2 (PRD: 50%).
    public var lowerIntensity: Double
    /// Upper bound of Zone 1–2 (PRD: 70%).
    public var upperIntensity: Double
    /// HRR intensity considered "starting to warm up", used to detect a gradual rise.
    public var warmIntensity: Double

    public init(method: ZoneMethod = .karvonen, lowerIntensity: Double = 0.5, upperIntensity: Double = 0.7, warmIntensity: Double = 0.3) {
        self.method = method
        self.lowerIntensity = lowerIntensity
        self.upperIntensity = upperIntensity
        self.warmIntensity = warmIntensity
    }

    public static let standard = ZoneConfiguration()
}

/// The user's personal dynamic HR threshold.
public struct HeartRateZones: Codable, Sendable, Equatable {
    public let maxHR: Double
    public let restingHR: Double
    /// Lower bound of the ready zone (Zone 1–2).
    public let lowerBound: Double
    /// Upper bound of the ready zone.
    public let upperBound: Double
    /// "Starting to warm up" threshold (always ≤ lowerBound).
    public let warmBound: Double

    public init(physiology: UserPhysiology, configuration: ZoneConfiguration = .standard) {
        // The Tanaka formula (208 − 0.7 × age) is more accurate than 220 − age for adults.
        let maxHR = 208 - 0.7 * Double(physiology.age)
        let rhr = min(physiology.restingHR, maxHR - 20)
        let reserve = maxHR - rhr

        func target(_ intensity: Double) -> Double {
            switch configuration.method {
            case .karvonen: rhr + intensity * reserve
            case .percentMaxHR: intensity * maxHR
            }
        }

        self.maxHR = maxHR
        self.restingHR = rhr
        self.lowerBound = target(configuration.lowerIntensity)
        self.upperBound = target(configuration.upperIntensity)
        self.warmBound = min(rhr + configuration.warmIntensity * reserve, target(configuration.lowerIntensity))
    }

    public func isInReadyZone(_ bpm: Double) -> Bool { bpm >= lowerBound }

    public var rangeText: String { "\(Int(lowerBound.rounded()))–\(Int(upperBound.rounded())) bpm" }
}
