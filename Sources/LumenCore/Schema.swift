import Foundation

/// The strict response formats shared by planning and critique.
enum PlanSchema {
    static func plan() -> Data {
        data(object([
            "summary": string("A one-line description of the proposed edit."),
            "steps": steps(),
        ]))
    }

    static func critique() -> Data {
        data(object([
            "satisfied": ["type": "boolean", "description": "Whether the photo now meets the instruction."],
            "notes": string("What the result gets right and what still needs changing."),
            "steps": steps(),
        ]))
    }

    private static func steps() -> [String: Any] {
        [
            "type": "array",
            "description": "Steps in execution order. Select a region before using its id; finish last.",
            "items": ["anyOf": [
                step("select", properties: [
                    "id": string("A unique, nonempty region id, such as sky, used by later steps."),
                    "concept": string("What to find, in a few words; at most 500 characters, or null for box or points.", nullable: true),
                    "box": rect(nullable: true),
                    "points": ["type": "array", "description": "Points on the subject; empty if unused.", "items": point()],
                    "invert": ["type": "boolean", "description": "True selects everything except the subject."],
                ]),
                step("adjust", properties: [
                    "region": string("An earlier selected region id, or null for the whole photo.", nullable: true),
                    "values": values(),
                ]),
                step("regenerate", properties: [
                    "region": string("An earlier selected region id to redraw."),
                    "prompt": string("Describe the desired pixels inside the region in 1 to 500 characters."),
                ]),
                step("remove", properties: [
                    "region": string("An earlier selected region id to remove and fill from its surroundings."),
                ]),
                step("crop", properties: ["rect": rect()]),
                step("finish", properties: ["reason": string("Why the edit is complete.")]),
            ]],
        ]
    }

    private static func step(_ type: String, properties: [String: Any]) -> [String: Any] {
        var properties = properties
        properties["type"] = ["type": "string", "enum": [type], "description": "The kind of edit step."]
        return object(properties)
    }

    private static func values() -> [String: Any] {
        let properties = Dictionary(uniqueKeysWithValues: AdjustmentKey.allCases.map { key in
            let units = key == .exposure ? "stops" : "percent"
            return (key.rawValue, [
                "type": ["number", "null"],
                "description": "\(key.rawValue) in \(units), \(key.range.lowerBound)...\(key.range.upperBound); null leaves it unchanged.",
            ] as [String: Any])
        })
        return object(properties, description: "Develop settings to change; use null for unused settings.")
    }

    private static func rect(nullable: Bool = false) -> [String: Any] {
        object([
            "x": number("Left edge, 0...1 of the photo width from the left."),
            "y": number("Top edge, 0...1 of the photo height from the top."),
            "width": number("Width as a share of the photo, greater than 0 and at most 1 minus x."),
            "height": number("Height as a share of the photo, greater than 0 and at most 1 minus y."),
        ], nullable: nullable, description: "A rectangle in normalized photo coordinates\(nullable ? ", or null if unused" : "").")
    }

    private static func point() -> [String: Any] {
        object([
            "x": number("Horizontal position, 0...1 of the photo width from the left."),
            "y": number("Vertical position, 0...1 of the photo height from the top."),
        ])
    }

    private static func string(_ description: String, nullable: Bool = false) -> [String: Any] {
        ["type": nullable ? ["string", "null"] : "string", "description": description]
    }

    private static func number(_ description: String) -> [String: Any] {
        ["type": "number", "description": description]
    }

    private static func object(_ properties: [String: Any], nullable: Bool = false, description: String? = nil) -> [String: Any] {
        var schema: [String: Any] = [
            "type": nullable ? ["object", "null"] : "object",
            "properties": properties,
            "required": properties.keys.sorted(),
            "additionalProperties": false,
        ]
        if let description { schema["description"] = description }
        return schema
    }

    private static func data(_ schema: [String: Any]) -> Data {
        // These schemas contain only JSON literals built above.
        try! JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys])
    }
}
