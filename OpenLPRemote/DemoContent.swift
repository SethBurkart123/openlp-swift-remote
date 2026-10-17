import Foundation

enum DemoContent {
    struct Item {
        let title: String
        let plugin: String
        let slides: [String]
        var preview: String? = nil
    }
    static let items: [Item] = [
        Item(title: "Welcome", plugin: "custom", slides: ["Welcome\nWe’re glad you’re here."]),
        Item(title: "Morning Light", plugin: "songs", slides: [
            "A new day is beginning,\nThe morning fills the sky.\nWe gather here together,\nWith grateful hearts held high.",
            "Let kindness be our anthem,\nLet hope become our song.\nWith open hearts and willing hands,\nTogether we belong.",
            "In every quiet moment,\nIn every helping hand,\nWe find a little courage,\nAnd strength to understand.",
            "Let kindness be our anthem,\nLet hope become our song.\nWith open hearts and willing hands,\nTogether we belong."
        ]),
        Item(title: "Opening Prayer", plugin: "custom", slides: ["A moment of reflection"]),
        Item(title: "Sample Image", plugin: "images", slides: ["Big Buck Bunny · Sample still"], preview: "demo-bunny"),
        Item(title: "Big Buck Bunny", plugin: "media", slides: ["Big Buck Bunny"], preview: "demo-bunny"),
        Item(title: "Reading", plugin: "bibles", slides: ["Today’s reading\nA time for reflection."]),
        Item(title: "Closing Prayer", plugin: "custom", slides: ["Go in peace"]),
        Item(title: "Thank You", plugin: "custom", slides: ["Thank you for joining us."])
    ]
}
