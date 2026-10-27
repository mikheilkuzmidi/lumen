import Foundation
import LumenCore

/// Strict response formats for reviewing and planning a library.
enum MetaBatchSchema {
    static func review() -> Data {
        data(object(["photos": array(object([
            "number": ["type": "integer", "minimum": 1],
            "misfire": ["type": "boolean"],
            "misfireReason": ["type": ["string", "null"]],
            "quality": ["type": "number", "minimum": 0, "maximum": 1],
            "description": ["type": "string"],
            "group": ["type": "string"],
            "matchesInstruction": ["type": "boolean"],
            "tilted": ["type": "boolean"],
            "levelLine": ["type": "string", "enum": LevelLine.allCases.map(\.rawValue)],
        ]))]))
    }

    static func plan() -> Data {
        data(object([
            "summary": ["type": "string"],
            "groups": array(object([
                "id": ["type": "string"],
                "title": ["type": "string"],
                "photos": array(["type": "integer", "minimum": 1]),
                "instruction": ["type": ["string", "null"]],
            ])),
            "questions": array(object([
                "id": ["type": "string"],
                "question": ["type": "string"],
                "options": ["type": "array", "items": ["type": "string"], "minItems": 2, "maxItems": 4],
                "recommended": ["type": "integer", "minimum": 0, "maximum": 3],
                "groups": array(["type": "string"]),
            ])),
        ]))
    }

    private static func array(_ items: [String: Any]) -> [String: Any] {
        ["type": "array", "items": items]
    }

    private static func object(_ properties: [String: Any]) -> [String: Any] {
        ["type": "object", "properties": properties, "required": properties.keys.sorted(), "additionalProperties": false]
    }

    private static func data(_ schema: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys])
    }
}
