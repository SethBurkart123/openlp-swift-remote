import SwiftUI

extension KeyedDecodingContainer {
    func flexibleString(_ key: Key) -> String? {
        if let value = try? decode(String.self, forKey: key) { return value }
        if let value = try? decode(Int.self, forKey: key) { return String(value) }
        return nil
    }
}

struct Envelope<T: Decodable>: Decodable { let results: T }
struct ServiceResult: Decodable { let items: [ServiceItem] }
struct ServiceItem: Decodable, Identifiable {
    let id: String
    let title: String
    let selected: Bool
    let plugin: String?
    enum CodingKeys: String, CodingKey { case id, title, selected, plugin }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let identifier = c.flexibleString(.id) else {
            throw DecodingError.keyNotFound(CodingKeys.id, .init(codingPath: decoder.codingPath, debugDescription: "Missing service identifier"))
        }
        id = identifier
        title = c.flexibleString(.title) ?? "Untitled item"
        selected = (try? c.decode(Bool.self, forKey: .selected)) ?? false
        plugin = c.flexibleString(.plugin)
    }
    var typeIcon: String {
        switch plugin {
        case "songs": return "music.note"
        case "bibles": return "book.closed"
        case "images": return "photo"
        case "media": return "play.rectangle"
        case "presentations": return "rectangle.on.rectangle"
        case "custom": return "text.alignleft"
        default: return "doc.text"
        }
    }
    var typeLabel: String {
        switch plugin {
        case "songs": return "Song"
        case "bibles": return "Bible reading"
        case "images": return "Images"
        case "media": return "Media"
        case "presentations": return "Presentation"
        case "custom": return "Custom slides"
        default: return "Service item"
        }
    }
}
struct MediaStatus: Decodable {
    let item: String
    let playing: Bool
    let position: Int
    let start: Int
    let duration: Int
    let seekable: Bool
}
struct SlideResult: Decodable {
    let item: String?
    let slides: [Slide]
    let media: MediaStatus?
    enum CodingKeys: String, CodingKey { case item, id, slides, media }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        item = c.flexibleString(.item) ?? c.flexibleString(.id)
        slides = try c.decodeIfPresent([Slide].self, forKey: .slides) ?? []
        // Fork-specific extensions must never break basic slide browsing.
        media = try? c.decode(MediaStatus.self, forKey: .media)
    }
}
struct Slide: Decodable {
    let text: String
    let title: String
    let selected: Bool
    let img: String?
    enum CodingKeys: String, CodingKey { case text, title, selected, img }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = c.flexibleString(.title) ?? ""
        text = c.flexibleString(.text) ?? title
        selected = (try? c.decode(Bool.self, forKey: .selected)) ?? false
        img = c.flexibleString(.img)
    }
}
struct Poll: Decodable {
    let blank: Bool
    let theme: Bool
    let display: Bool
}
enum DisplayMode: String, CaseIterable {
    case blank = "Blank", theme = "Theme", desktop = "Desktop", show = "Show"
}

enum PendingSelection: Equatable {
    case service(String)
    case slide(String, Int)
    case display(DisplayMode)
}

@MainActor final class Remote: ObservableObject {
    @Published var host = UserDefaults.standard.string(forKey: "host") ?? ""
    @Published var port = UserDefaults.standard.string(forKey: "port") ?? "4316"
    @Published var https = UserDefaults.standard.bool(forKey: "https")
    @Published var needsAuth = UserDefaults.standard.bool(forKey: "needsAuth")
    @Published var username = UserDefaults.standard.string(forKey: "username") ?? ""
    @Published var password = ""
    @Published var controlsEnabled = UserDefaults.standard.object(forKey: "controlsEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(controlsEnabled, forKey: "controlsEnabled") }
    }
    @Published var items: [ServiceItem] = []
    @Published var slides: [Slide] = []
    @Published var media: MediaStatus?
    @Published private var mediaReceivedAt = Date()
    @Published private var optimisticMedia: MediaStatus?
    private var optimisticMediaAt = Date()
    var displayedMedia: MediaStatus? {
        if let optimisticMedia, optimisticMedia.item == media?.item { return optimisticMedia }
        return media
    }
    func mediaPosition(at date: Date = Date()) -> Double {
        guard let status = displayedMedia else { return 0 }
        let anchor = optimisticMedia?.item == status.item ? optimisticMediaAt : mediaReceivedAt
        let elapsed = status.playing && connected ? max(0, date.timeIntervalSince(anchor)) * 1000 : 0
        return max(Double(status.start), min(Double(status.duration), Double(status.position) + elapsed))
    }
    @Published var slideItem: String?
    @Published var mode: DisplayMode = .show
    @Published var displayStateKnown = false
    @Published var apiName = "Detecting"
    private enum API { case legacy, v2 }
    private var api: API?
    private var token: String?
    private var pollSupported = true
    @Published var connected = false
    @Published var error: String?
    @Published var commandError: String?
    @Published var busy = false
    @Published var pending: PendingSelection?
    @Published var updated: Date?
    private var refreshing = false
    private var generation = 0
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()
    var baseURL: URL? {
        var c = URLComponents()
        c.scheme = https ? "https" : "http"
        c.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let p = Int(port), (1...65535).contains(p), !host.isEmpty else { return nil }
        c.port = p
        return c.url
    }
    var title: String { items.first(where: { $0.id == slideItem })?.title ?? slides.first?.title ?? "Current item" }
    var canControl: Bool { controlsEnabled && connected }
    func save() {
        pending = nil
        generation += 1
        api = nil; token = nil; pollSupported = true; displayStateKnown = false; apiName = "Detecting"
        connected = false
        items = []; slides = []; slideItem = nil; media = nil; optimisticMedia = nil
        let d = UserDefaults.standard
        d.set(host, forKey: "host"); d.set(port, forKey: "port")
        d.set(https, forKey: "https"); d.set(needsAuth, forKey: "needsAuth")
        d.set(username, forKey: "username")
    }
    private func request(_ path: String, index: Int? = nil, body: [String: Any]? = nil, authorization: String? = nil) async throws -> Data {
        guard let baseURL, var c = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw RemoteError.message("Enter a server IP or hostname and a valid port in Settings.")
        }
        c.path = path.removingPercentEncoding ?? path
        if let index { c.queryItems = [URLQueryItem(name: "data", value: "{\"request\":{\"id\":\(index)}}")] }
        guard let url = c.url else { throw RemoteError.message("Invalid server address.") }
        var req = URLRequest(url: url)
        if let body {
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        if let authorization { req.setValue(authorization, forHTTPHeaderField: "Authorization") }
        else if needsAuth {
            req.setValue("Basic " + Data("\(username):\(password)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await session.data(for: req)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw RemoteError.http(code)
        }
        return data
    }
    private func read<T: Decodable>(_ path: String, as type: T.Type) async throws -> T {
        try JSONDecoder().decode(Envelope<T>.self, from: await request(path)).results
    }
    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        let current = generation
        do {
            var service: ServiceResult
            var live: SlideResult
            if api == .v2 {
                service = ServiceResult(items: try JSONDecoder().decode([ServiceItem].self,
                    from: await request("/api/v2/service/items")))
                live = try JSONDecoder().decode(SlideResult.self, from: await request("/api/v2/controller/live-items"))
            } else {
                do {
                    service = try await read("/api/service/list", as: ServiceResult.self)
                    live = try await read("/api/controller/live/text", as: SlideResult.self)
                    api = .legacy; apiName = "Legacy API (OpenLP 2 / 3)"
                } catch RemoteError.http(let code) where code == 404 || code == 405 || code == 410 {
                    service = ServiceResult(items: try JSONDecoder().decode([ServiceItem].self,
                        from: await request("/api/v2/service/items")))
                    live = try JSONDecoder().decode(SlideResult.self, from: await request("/api/v2/controller/live-items"))
                    api = .v2; apiName = "API v2"
                }
            }
            let mediaSampleTime = Date()
            var poll: Poll?
            if pollSupported {
                do { poll = try await read("/api/poll", as: Poll.self) }
                catch RemoteError.http(let code) where code == 404 || code == 405 || code == 410 {
                    pollSupported = false
                } catch { /* Display state is optional; service and slide controls still work. */ }
            }
            guard current == generation else { return }
            items = service.items; slides = live.slides
            slideItem = live.item ?? service.items.first(where: { $0.selected })?.id
            media = live.media; mediaReceivedAt = mediaSampleTime
            displayStateKnown = poll != nil
            if let poll { mode = poll.blank ? .blank : poll.theme ? .theme : poll.display ? .desktop : .show }
            connected = true; error = nil; updated = Date()
        } catch {
            guard current == generation, !Task.isCancelled else { return }
            connected = false
            self.error = error.localizedDescription
        }
    }
    private func command(_ path: String, index: Int?) async throws {
        guard api == .v2 else { _ = try await request(path, index: index); return }
        var destination: String
        var body: [String: Any]
        if path == "/api/service/set", let index {
            destination = "/api/v2/service/show"; body = ["id": items[index].id]
        } else if path == "/api/controller/live/set", let index {
            destination = "/api/v2/controller/show"; body = ["id": index]
        } else if path.hasPrefix("/api/service/direction/") {
            destination = "/api/v2/service/progress"; body = ["action": String(path.split(separator: "/").last!)]
        } else if path.hasPrefix("/api/display/") {
            destination = "/api/v2/core/display"; body = ["display": String(path.split(separator: "/").last!)]
        } else {
            destination = "/api/v2/controller/progress"; body = ["action": String(path.split(separator: "/").last!)]
        }
        if needsAuth && token == nil { try await login() }
        do { _ = try await request(destination, body: body, authorization: token) }
        catch RemoteError.http(401) where needsAuth {
            // A 401 rejects the command before dispatch; renewing the token is safe.
            token = nil
            try await login()
            _ = try await request(destination, body: body, authorization: token)
        }
    }
    private func login() async throws {
        struct Login: Decodable { let token: String }
        token = try JSONDecoder().decode(Login.self, from: await request("/api/v2/core/login",
            body: ["username": username, "password": password])).token
    }
    private func target(for path: String, index: Int?) -> PendingSelection? {
        if path == "/api/service/set", let index, items.indices.contains(index) {
            return .service(items[index].id)
        }
        if path == "/api/controller/live/set", let index, let slideItem {
            return .slide(slideItem, index)
        }
        if path.hasPrefix("/api/display/"), let mode = DisplayMode.allCases.first(where: { path.hasSuffix($0.rawValue.lowercased()) }) {
            return .display(mode)
        }
        let offset = path.hasSuffix("/next") ? 1 : -1
        if path.hasPrefix("/api/service/direction/"), let selected = items.firstIndex(where: { $0.selected }), items.indices.contains(selected + offset) {
            return .service(items[selected + offset].id)
        }
        if path.hasPrefix("/api/controller/live/"), let slideItem, let selected = slides.firstIndex(where: { $0.selected }), slides.indices.contains(selected + offset) {
            return .slide(slideItem, selected + offset)
        }
        return nil
    }
    private func confirmed(_ selection: PendingSelection) -> Bool {
        switch selection {
        case .service(let id): return slideItem == id && items.contains { $0.id == id && $0.selected }
        case .slide(let item, let index): return slideItem == item && slides.indices.contains(index) && slides[index].selected
        case .display(let expected): return mode == expected
        }
    }
    func servicePending(_ id: String) -> Bool { pending == .service(id) }
    func slidePending(_ index: Int) -> Bool {
        guard let slideItem else { return false }
        return pending == .slide(slideItem, index)
    }
    @discardableResult
    func send(_ path: String, index: Int? = nil) async -> Bool {
        // Serialize commands without dimming the controls. The softer selection
        // represents intent; only read-back from OpenLP changes the live selection.
        guard canControl && !busy else { return false }
        let current = generation
        let selection = target(for: path, index: index)
        pending = selection
        busy = true
        defer { busy = false; pending = nil }
        do {
            try await command(path, index: index)
            // Some v2-only servers expose display status only via WebSocket.
            // Accept HTTP acknowledgement without inventing a confirmed display mode.
            if path.hasPrefix("/api/display/") && !displayStateKnown { return true }
            let deadline = Date().addingTimeInterval(8)
            repeat {
                try await Task.sleep(for: .milliseconds(200))
                guard current == generation, controlsEnabled else { return false }
                await refresh()
                guard connected else { throw RemoteError.message(error ?? "Connection lost.") }
                if let selection {
                    if confirmed(selection) { return true }
                } else { return true }
            } while Date() < deadline
            throw RemoteError.message("OpenLP has not confirmed the requested selection yet.")
        } catch {
            commandError = "Could not confirm the command. Check the projection before retrying. \(error.localizedDescription)"
            return false
        }
    }
    func controlMedia(_ action: String, position: Int? = nil) async {
        guard canControl, !busy, let target = media else { return }
        let localPosition = Int(mediaPosition())
        let nextPosition = action == "stop" ? target.start : position ?? localPosition
        let playing = action == "play" ? true : (action == "pause" || action == "stop" ? false : target.playing)
        optimisticMediaAt = Date()
        optimisticMedia = MediaStatus(item: target.item, playing: playing,
            position: max(target.start, min(nextPosition, target.duration)), start: target.start,
            duration: target.duration, seekable: target.seekable)
        busy = true
        defer { busy = false; optimisticMedia = nil }
        let current = generation
        do {
            var body: [String: Any] = ["item": target.item]
            if let position { body["position"] = position }
            _ = try await request("/api/controller/live/media/\(action)", body: body)
            let deadline = Date().addingTimeInterval(5)
            repeat {
                try await Task.sleep(for: .milliseconds(200))
                await refresh()
                guard current == generation, slideItem == target.item else { return }
                if let media {
                    if action == "play" && media.playing { return }
                    if action == "pause" && !media.playing { return }
                    if action == "stop" && !media.playing && abs(media.position - media.start) < 1000 { return }
                    if action == "seek", let position, abs(media.position - position) < 1500 { return }
                }
            } while Date() < deadline
            throw RemoteError.message("OpenLP has not confirmed the playback change yet.")
        } catch {
            commandError = error.localizedDescription
        }
    }
    var previewRevision: Int { generation }
    func loadPreview(_ path: String) async throws -> UIImage {
        if path.hasPrefix("data:image/"), path.utf8.count <= 14_000_000,
           let comma = path.firstIndex(of: ","), path[..<comma].hasSuffix(";base64"),
           let data = Data(base64Encoded: String(path[path.index(after: comma)...])),
           let image = UIImage(data: data) { return image }
        let allowed = ["/api/controller/live/thumbnail/", "/images/", "/media/", "/presentations/"]
        guard allowed.contains(where: { path.hasPrefix($0) }) else {
            throw RemoteError.message("Unsupported preview address.")
        }
        // Use the same origin and authentication as API requests. AsyncImage
        // does not attach the user's configured Authorization header.
        let data = try await request(path)
        guard data.count <= 10_000_000, let image = UIImage(data: data) else {
            throw RemoteError.message("Preview image is unavailable.")
        }
        return image
    }

}
enum RemoteError: LocalizedError {
    case message(String)
    case http(Int)
    var errorDescription: String? {
        switch self {
        case .message(let message): return message
        case .http(401), .http(403): return "Authentication required. Check Settings."
        case .http(404): return "This OpenLP server does not provide the requested feature."
        case .http(let code): return "Server returned HTTP \(code)."
        }
    }
}

@main struct OpenLPRemoteApp: App {
    @StateObject private var remote = Remote()
    var body: some Scene { WindowGroup { RootView().environmentObject(remote) } }
}
struct RootView: View {
    @EnvironmentObject var remote: Remote
    @Environment(\.scenePhase) private var scenePhase
    @State private var settings = false
    @State private var tab = 0
    var body: some View {
        TabView(selection: $tab) {
            page(slides: false).tabItem { Label("Service", systemImage: "list.bullet.rectangle") }.tag(0)
            page(slides: true).tabItem { Label("Slides", systemImage: "rectangle.on.rectangle") }.tag(1)
        }
        .tint(.blue)
        .sheet(isPresented: $settings) { SettingsView() }
        .alert("Command not confirmed", isPresented: Binding(get: { remote.commandError != nil }, set: { if !$0 { remote.commandError = nil } })) {
            Button("OK") { remote.commandError = nil }
        } message: { Text(remote.commandError ?? "") }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                if scenePhase == .active && !settings { await remote.refresh() }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
    private func page(slides: Bool) -> some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let error = remote.error {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(error).font(.callout)
                        Button("Connection settings") { settings = true }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding().background(Color.orange.opacity(0.1))
                }
                if slides { slideList } else { serviceList }
                if let media = remote.displayedMedia {
                    MediaControls(media: media).id(media.item)
                }
                VStack(spacing: 0) {
                    Divider()
                    Picker("Display", selection: Binding<DisplayMode?>(get: { remote.displayStateKnown ? remote.mode : nil }, set: { mode in
                        guard let mode else { return }
                        Task { await remote.send("/api/display/\(mode.rawValue.lowercased())") }
                    })) {
                        ForEach(DisplayMode.allCases, id: \.self) { Text($0.rawValue).tag(Optional($0)) }
                    }
                    .pickerStyle(.segmented).disabled(!remote.canControl).allowsHitTesting(!remote.busy).padding(.horizontal, 16).padding(.vertical, 8)
                }.background(.bar)
            }
            .navigationTitle(slides ? "Slides" : "Service").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { settings = true } label: { Image(systemName: "gearshape").font(.title2) }.accessibilityLabel("Settings")
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { direction(slides, "previous") } label: { Image(systemName: "chevron.up").font(.title2).frame(width: 38, height: 36) }
                        .accessibilityLabel(slides ? "Previous slide" : "Previous service item").disabled(!remote.canControl).allowsHitTesting(!remote.busy)
                    Button { direction(slides, "next") } label: { Image(systemName: "chevron.down").font(.title2).frame(width: 38, height: 36) }
                        .accessibilityLabel(slides ? "Next slide" : "Next service item").disabled(!remote.canControl).allowsHitTesting(!remote.busy)
                }
            }
        }
    }
    private func direction(_ slides: Bool, _ direction: String) {
        Task { await remote.send(slides ? "/api/controller/live/\(direction)" : "/api/service/direction/\(direction)") }
    }
    private func selectionColor(live: Bool, pending: Bool) -> Color {
        live ? Color.blue.opacity(0.28) : pending ? Color.blue.opacity(0.10) : Color(uiColor: .systemBackground)
    }
    private var serviceList: some View {
        List {
            ForEach(Array(remote.items.enumerated()), id: \.element.id) { index, item in
                Button {
                    guard remote.canControl else { return }
                    Task {
                        let confirmed = await remote.send("/api/service/set", index: index)
                        if confirmed && remote.slideItem == item.id && remote.slides.count > 1 { tab = 1 }
                    }
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Image(systemName: item.typeIcon)
                            .font(.body).foregroundStyle(.secondary)
                            .frame(width: 24).accessibilityHidden(true)
                        Text(item.title).font(.title3).foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(item.typeLabel), \(item.title)")
                }
                .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
                .allowsHitTesting(!remote.busy)
                .listRowBackground(selectionColor(live: item.selected, pending: remote.servicePending(item.id)))
                .accessibilityValue(item.selected ? "Live" : remote.servicePending(item.id) ? "Requested, waiting for OpenLP" : "")
            }
        }
        .listStyle(.plain).refreshable { await remote.refresh() }
        .overlay { if remote.items.isEmpty && remote.connected { ContentUnavailableView("No service items", systemImage: "list.bullet.rectangle", description: Text("Add items on the OpenLP computer.")) } }
    }
    private var slideList: some View {
        List {
            ForEach(Array(remote.slides.enumerated()), id: \.offset) { index, slide in
                Button {
                    Task { await remote.send("/api/controller/live/set", index: index) }
                } label: {
                    VStack(alignment: .leading, spacing: 10) {
                        if let path = slide.img {
                            MediaPreview(path: path)
                        }
                        Text(slide.text).font(.title3).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
                .allowsHitTesting(!remote.busy)
                .listRowBackground(selectionColor(live: slide.selected, pending: remote.slidePending(index)))
                .accessibilityValue(slide.selected ? "Live" : remote.slidePending(index) ? "Requested, waiting for OpenLP" : "")
            }
        }.listStyle(.plain).refreshable { await remote.refresh() }
        .overlay { if remote.slides.isEmpty && remote.connected { ContentUnavailableView("No live slides", systemImage: "rectangle.on.rectangle", description: Text("Slides appear when an item is live in OpenLP.")) } }
    }
}

struct MediaControls: View {
    @EnvironmentObject var remote: Remote
    let media: MediaStatus
    @State private var seeking = false
    @State private var seekPosition = 0.0
    private func time(_ milliseconds: Int) -> String {
        let seconds = max(0, milliseconds / 1000)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
    private func skip(_ delta: Int) {
        let target = max(media.start, min(Int(remote.mediaPosition()) + delta, media.duration))
        Task { await remote.controlMedia("seek", position: target) }
    }
    var body: some View {
        VStack(spacing: 6) {
            Divider()
            HStack(spacing: 28) {
                Button { skip(-10_000) } label: { Image(systemName: "gobackward.10") }
                    .disabled(!media.seekable).accessibilityLabel("Back ten seconds")
                Button { Task { await remote.controlMedia(media.playing ? "pause" : "play") } } label: {
                    Image(systemName: media.playing ? "pause.fill" : "play.fill")
                }.accessibilityLabel(media.playing ? "Pause video" : "Play video")
                Button { Task { await remote.controlMedia("stop") } } label: { Image(systemName: "stop.fill") }
                    .accessibilityLabel("Stop video")
                Button { skip(10_000) } label: { Image(systemName: "goforward.10") }
                    .disabled(!media.seekable).accessibilityLabel("Forward ten seconds")
            }.font(.title3).buttonStyle(.borderless).frame(height: 44)
            if media.seekable && media.duration > media.start {
                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !media.playing || seeking)) { context in
                    let position = seeking ? seekPosition : remote.mediaPosition(at: context.date)
                    Slider(value: Binding(get: { position }, set: {
                        seekPosition = $0
                        seeking = true
                    }), in: Double(media.start)...Double(media.duration), onEditingChanged: { editing in
                        if !editing {
                            let target = Int(seekPosition)
                            seeking = false
                            Task { await remote.controlMedia("seek", position: target) }
                        }
                    }).accessibilityLabel("Video position")
                    HStack {
                        Text(time(Int(position)))
                        Spacer()
                        Text(time(media.duration))
                    }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 16).padding(.bottom, 8)
        .disabled(!remote.canControl)
        .allowsHitTesting(!remote.busy)
    }
}

struct MediaPreview: View {
    @EnvironmentObject var remote: Remote
    let path: String
    @State private var image: UIImage?
    @State private var failed = false
    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
                    .frame(maxHeight: 240).frame(maxWidth: .infinity)
                    .accessibilityLabel("Slide preview")
            } else if failed {
                Label("Preview unavailable", systemImage: "photo")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ProgressView().frame(maxWidth: .infinity).frame(height: 90)
            }
        }
        .task(id: "\(remote.previewRevision):\(path)") {
            image = nil; failed = false
            do {
                let loaded = try await remote.loadPreview(path)
                guard !Task.isCancelled else { return }
                image = loaded
            } catch {
                guard !Task.isCancelled else { return }
                failed = true
            }
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var remote: Remote
    @Environment(\.dismiss) var dismiss
    @State private var host = ""
    @State private var port = ""
    @State private var https = false
    @State private var auth = false
    @State private var username = ""
    @State private var password = ""
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack { Text("Server IP"); TextField("openlp.local", text: $host).multilineTextAlignment(.trailing).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL) }
                    HStack { Text("Server port"); TextField("4316", text: $port).multilineTextAlignment(.trailing).keyboardType(.numberPad) }
                    Toggle("Use HTTPS", isOn: $https)
                }
                Section {
                    Toggle("Needs auth", isOn: $auth)
                    if auth {
                        TextField("Username", text: $username).textInputAutocapitalization(.never).autocorrectionDisabled()
                        SecureField("Password", text: $password)
                    }
                } footer: { if auth { Text("Password is kept for this session only.") } }
                Section {
                    Toggle("Enable live controls", isOn: $remote.controlsEnabled)
                } footer: {
                    Text("When enabled, tapping items, arrows or display controls changes the live projection. Your choice is remembered. Controls reconnect automatically when the server is available.")
                }
                Section {
                    LabeledContent("API", value: remote.apiName)
                    LabeledContent("Connection", value: remote.connected ? "Connected" : "Disconnected")
                    if let updated = remote.updated { LabeledContent("Last update", value: updated.formatted(date: .omitted, time: .standard)) }
                    Button("Save and check connection") { apply(); Task { await remote.refresh() } }
                    if let error = remote.error { Text(error).font(.footnote).foregroundStyle(.red) }
                }
                Section { Link("About OpenLP", destination: URL(string: "https://openlp.org")!).frame(maxWidth: .infinity) }
            }
            .navigationTitle("Settings").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("OK") { if changed { apply() }; dismiss(); Task { await remote.refresh() } }.bold() } }
            .onAppear { host = remote.host; port = remote.port; https = remote.https; auth = remote.needsAuth; username = remote.username; password = remote.password }

        }
    }
    private var changed: Bool { host != remote.host || port != remote.port || https != remote.https || auth != remote.needsAuth || username != remote.username || password != remote.password }
    private func apply() {
        remote.host = host; remote.port = port; remote.https = https; remote.needsAuth = auth
        remote.username = username; remote.password = password; remote.save()
    }
}
