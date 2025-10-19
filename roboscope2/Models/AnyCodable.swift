//
//  AnyCodable.swift
//  roboscope2
//
//  Utility for encoding/decoding arbitrary JSON values
//

import Foundation

/// A type-erased codable value that can represent any JSON-compatible type
struct AnyCodable: Codable, Hashable {
    let value: Any
    
    init(_ value: Any) {
        self.value = value
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        
        if container.decodeNil() {
            value = NSNull()
        } else if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let int = try? container.decode(Int.self) {
            value = int
        } else if let int8 = try? container.decode(Int8.self) {
            value = int8
        } else if let int16 = try? container.decode(Int16.self) {
            value = int16
        } else if let int32 = try? container.decode(Int32.self) {
            value = int32
        } else if let int64 = try? container.decode(Int64.self) {
            value = int64
        } else if let uint = try? container.decode(UInt.self) {
            value = uint
        } else if let uint8 = try? container.decode(UInt8.self) {
            value = uint8
        } else if let uint16 = try? container.decode(UInt16.self) {
            value = uint16
        } else if let uint32 = try? container.decode(UInt32.self) {
            value = uint32
        } else if let uint64 = try? container.decode(UInt64.self) {
            value = uint64
        } else if let float = try? container.decode(Float.self) {
            value = float
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let string = try? container.decode(String.self) {
            value = string
        } else if let array = try? container.decode([AnyCodable].self) {
            value = array.map { $0.value }
        } else if let dictionary = try? container.decode([String: AnyCodable].self) {
            value = dictionary.mapValues { $0.value }
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "AnyCodable value cannot be decoded"
            )
        }
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        
        switch value {
        case is NSNull:
            try container.encodeNil()
        case let bool as Bool:
            try container.encode(bool)
        case let int as Int:
            try container.encode(int)
        case let int8 as Int8:
            try container.encode(int8)
        case let int16 as Int16:
            try container.encode(int16)
        case let int32 as Int32:
            try container.encode(int32)
        case let int64 as Int64:
            try container.encode(int64)
        case let uint as UInt:
            try container.encode(uint)
        case let uint8 as UInt8:
            try container.encode(uint8)
        case let uint16 as UInt16:
            try container.encode(uint16)
        case let uint32 as UInt32:
            try container.encode(uint32)
        case let uint64 as UInt64:
            try container.encode(uint64)
        case let float as Float:
            try container.encode(float)
        case let double as Double:
            try container.encode(double)
        case let string as String:
            try container.encode(string)
        case let array as [Any]:
            try container.encode(array.map { AnyCodable($0) })
        case let dictionary as [String: Any]:
            try container.encode(dictionary.mapValues { AnyCodable($0) })
        default:
            let context = EncodingError.Context(
                codingPath: container.codingPath,
                debugDescription: "AnyCodable value cannot be encoded"
            )
            throw EncodingError.invalidValue(value, context)
        }
    }
    
    static func == (lhs: AnyCodable, rhs: AnyCodable) -> Bool {
        switch (lhs.value, rhs.value) {
        case is (NSNull, NSNull):
            return true
        case let (lhs as Bool, rhs as Bool):
            return lhs == rhs
        case let (lhs as Int, rhs as Int):
            return lhs == rhs
        case let (lhs as Int8, rhs as Int8):
            return lhs == rhs
        case let (lhs as Int16, rhs as Int16):
            return lhs == rhs
        case let (lhs as Int32, rhs as Int32):
            return lhs == rhs
        case let (lhs as Int64, rhs as Int64):
            return lhs == rhs
        case let (lhs as UInt, rhs as UInt):
            return lhs == rhs
        case let (lhs as UInt8, rhs as UInt8):
            return lhs == rhs
        case let (lhs as UInt16, rhs as UInt16):
            return lhs == rhs
        case let (lhs as UInt32, rhs as UInt32):
            return lhs == rhs
        case let (lhs as UInt64, rhs as UInt64):
            return lhs == rhs
        case let (lhs as Float, rhs as Float):
            return lhs == rhs
        case let (lhs as Double, rhs as Double):
            return lhs == rhs
        case let (lhs as String, rhs as String):
            return lhs == rhs
        case let (lhs as [String: Any], rhs as [String: Any]):
            return NSDictionary(dictionary: lhs).isEqual(to: rhs)
        case let (lhs as [Any], rhs as [Any]):
            return NSArray(array: lhs).isEqual(to: rhs)
        default:
            return false
        }
    }
    
    func hash(into hasher: inout Hasher) {
        switch value {
        case let bool as Bool:
            hasher.combine(bool)
        case let int as Int:
            hasher.combine(int)
        case let int8 as Int8:
            hasher.combine(int8)
        case let int16 as Int16:
            hasher.combine(int16)
        case let int32 as Int32:
            hasher.combine(int32)
        case let int64 as Int64:
            hasher.combine(int64)
        case let uint as UInt:
            hasher.combine(uint)
        case let uint8 as UInt8:
            hasher.combine(uint8)
        case let uint16 as UInt16:
            hasher.combine(uint16)
        case let uint32 as UInt32:
            hasher.combine(uint32)
        case let uint64 as UInt64:
            hasher.combine(uint64)
        case let float as Float:
            hasher.combine(float)
        case let double as Double:
            hasher.combine(double)
        case let string as String:
            hasher.combine(string)
        case let array as [AnyHashable]:
            hasher.combine(array)
        case let dict as [String: AnyHashable]:
            hasher.combine(dict)
        default:
            hasher.combine(0) // Fallback for non-hashable types
        }
    }
}

// MARK: - Convenience Extensions

extension AnyCodable: ExpressibleByNilLiteral {
    init(nilLiteral: ()) {
        value = NSNull()
    }
}

extension AnyCodable: ExpressibleByBooleanLiteral {
    init(booleanLiteral value: Bool) {
        self.value = value
    }
}

extension AnyCodable: ExpressibleByIntegerLiteral {
    init(integerLiteral value: Int) {
        self.value = value
    }
}

extension AnyCodable: ExpressibleByFloatLiteral {
    init(floatLiteral value: Double) {
        self.value = value
    }
}

extension AnyCodable: ExpressibleByStringLiteral {
    init(stringLiteral value: String) {
        self.value = value
    }
}

extension AnyCodable: ExpressibleByArrayLiteral {
    init(arrayLiteral elements: Any...) {
        value = elements
    }
}

extension AnyCodable: ExpressibleByDictionaryLiteral {
    init(dictionaryLiteral elements: (String, Any)...) {
        value = Dictionary(uniqueKeysWithValues: elements)
    }
}

// MARK: - Type-safe Accessors

extension AnyCodable {
    /// Get the value as a specific type, or nil if it's not that type
    func get<T>() -> T? {
        return value as? T
    }
    
    /// Get the value as Bool, or nil
    var boolValue: Bool? {
        return value as? Bool
    }
    
    /// Get the value as Int, or nil
    var intValue: Int? {
        return value as? Int
    }
    
    /// Get the value as Double, or nil
    var doubleValue: Double? {
        return value as? Double
    }
    
    /// Get the value as String, or nil
    var stringValue: String? {
        return value as? String
    }
    
    /// Get the value as Array, or nil
    var arrayValue: [Any]? {
        return value as? [Any]
    }
    
    /// Get the value as Dictionary, or nil
    var dictionaryValue: [String: Any]? {
        return value as? [String: Any]
    }
}