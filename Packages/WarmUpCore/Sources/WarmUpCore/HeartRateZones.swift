import Foundation

public enum ZoneMethod: String, CaseIterable, Codable, Sendable {
    /// Karvonen / Heart Rate Reserve: RHR + intensitas × (MaxHR − RHR).
    case karvonen
    /// Persentase langsung dari Max HR: intensitas × MaxHR.
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
    /// Batas bawah Zona 1–2 (PRD: 50%).
    public var lowerIntensity: Double
    /// Batas atas Zona 1–2 (PRD: 70%).
    public var upperIntensity: Double
    /// Intensitas HRR yang dianggap "sudah mulai hangat" untuk deteksi tren kenaikan bertahap.
    public var warmIntensity: Double

    public init(method: ZoneMethod = .karvonen, lowerIntensity: Double = 0.5, upperIntensity: Double = 0.7, warmIntensity: Double = 0.3) {
        self.method = method
        self.lowerIntensity = lowerIntensity
        self.upperIntensity = upperIntensity
        self.warmIntensity = warmIntensity
    }

    public static let standard = ZoneConfiguration()
}

/// Dynamic HR Threshold personal pengguna.
public struct HeartRateZones: Codable, Sendable, Equatable {
    public let maxHR: Double
    public let restingHR: Double
    /// Batas bawah zona siap (Zona 1–2).
    public let lowerBound: Double
    /// Batas atas zona siap.
    public let upperBound: Double
    /// Ambang "mulai hangat" (selalu ≤ lowerBound).
    public let warmBound: Double

    public init(physiology: UserPhysiology, configuration: ZoneConfiguration = .standard) {
        // Formula Tanaka (208 − 0,7 × usia) lebih akurat dari 220 − usia untuk dewasa.
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
