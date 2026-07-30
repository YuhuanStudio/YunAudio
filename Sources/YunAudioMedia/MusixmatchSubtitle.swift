import Foundation

public struct MusixmatchAttribution: Equatable, Sendable {
    public var copyright: String?

    public init(copyright: String?) {
        self.copyright = copyright
    }
}

public struct MusixmatchTracking: Equatable, Sendable {
    public var scriptURL: URL?
    public var pixelURL: URL?

    public init(scriptURL: URL?, pixelURL: URL?) {
        self.scriptURL = scriptURL
        self.pixelURL = pixelURL
    }
}

public struct MusixmatchSubtitle: Equatable, Sendable {
    public var rawLRC: String
    public var attribution: MusixmatchAttribution
    public var tracking: MusixmatchTracking
    public var region: String?

    public init(
        rawLRC: String,
        attribution: MusixmatchAttribution,
        tracking: MusixmatchTracking,
        region: String?
    ) {
        self.rawLRC = rawLRC
        self.attribution = attribution
        self.tracking = tracking
        self.region = region
    }
}

public enum MusixmatchSubtitleFailure: Error, Equatable, Sendable {
    case missingAPIKey
    case invalidQuery
    case rateLimited(retryAfter: TimeInterval?)
    case serviceStatus(Int)
    case restricted(region: String?)
    case missingSubtitle
    case invalidResponse
}

public struct MusixmatchSubtitleAdapter: Sendable {
    public typealias Transport =
        @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    private let apiKey: String?
    private let transport: Transport

    public init(apiKey: String?, transport: @escaping Transport) {
        let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.apiKey = key?.isEmpty == false ? key : nil
        self.transport = transport
    }

    public var isConfigured: Bool {
        apiKey != nil
    }

    public func fetch(
        title: String,
        artist: String,
        duration: TimeInterval? = nil,
        maximumDurationDeviation: Int = 2
    ) async throws -> MusixmatchSubtitle {
        guard let apiKey else { throw MusixmatchSubtitleFailure.missingAPIKey }
        guard apiKey.count <= 1_024,
            (0...3_600).contains(maximumDurationDeviation)
        else {
            throw MusixmatchSubtitleFailure.invalidQuery
        }
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= MediaSnapshot.maximumTextLength,
            !artist.isEmpty, artist.count <= MediaSnapshot.maximumTextLength
        else {
            throw MusixmatchSubtitleFailure.invalidQuery
        }

        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.musixmatch.com"
        components.path = "/ws/1.1/matcher.subtitle.get"
        var queryItems = [
            URLQueryItem(name: "q_track", value: title),
            URLQueryItem(name: "q_artist", value: artist),
            URLQueryItem(name: "subtitle_format", value: "lrc"),
        ]
        if let duration {
            guard duration.isFinite, duration > 0, duration <= 86_400 else {
                throw MusixmatchSubtitleFailure.invalidQuery
            }
            queryItems.append(
                URLQueryItem(
                    name: "f_subtitle_length",
                    value: String(Int(duration.rounded()))))
            queryItems.append(
                URLQueryItem(
                    name: "f_subtitle_length_max_deviation",
                    value: String(maximumDurationDeviation)))
        }
        queryItems.append(URLQueryItem(name: "apikey", value: apiKey))
        components.queryItems = queryItems
        guard let url = components.url else {
            throw MusixmatchSubtitleFailure.invalidQuery
        }

        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 8)
        request.httpMethod = "GET"
        let (data, response) = try await transport(request)
        if response.statusCode == 429 {
            throw MusixmatchSubtitleFailure.rateLimited(
                retryAfter: Self.retryAfter(response))
        }
        guard (200..<300).contains(response.statusCode) else {
            throw MusixmatchSubtitleFailure.serviceStatus(response.statusCode)
        }
        guard data.count <= 2 * 1_024 * 1_024,
            let envelope = try? JSONDecoder().decode(Envelope.self, from: data)
        else {
            throw MusixmatchSubtitleFailure.invalidResponse
        }

        let status = envelope.message.header.statusCode
        if status == 429 {
            throw MusixmatchSubtitleFailure.rateLimited(
                retryAfter: Self.retryAfter(response))
        }
        guard status == 200 else {
            throw MusixmatchSubtitleFailure.serviceStatus(status)
        }
        guard let subtitle = envelope.message.body?.subtitle else {
            throw MusixmatchSubtitleFailure.missingSubtitle
        }
        let region = envelope.message.header.region
        guard !subtitle.restricted.value else {
            throw MusixmatchSubtitleFailure.restricted(region: region)
        }
        guard subtitle.subtitleBody.nonEmpty != nil else {
            throw MusixmatchSubtitleFailure.missingSubtitle
        }
        return MusixmatchSubtitle(
            rawLRC: subtitle.subtitleBody,
            attribution: MusixmatchAttribution(
                copyright: subtitle.lyricsCopyright?.nonEmpty),
            tracking: MusixmatchTracking(
                scriptURL: Self.webURL(subtitle.scriptTrackingURL),
                pixelURL: Self.webURL(subtitle.pixelTrackingURL)),
            region: region)
    }

    private static func retryAfter(_ response: HTTPURLResponse) -> TimeInterval? {
        guard let value = response.value(forHTTPHeaderField: "Retry-After"),
            let seconds = TimeInterval(value),
            seconds.isFinite,
            seconds >= 0
        else { return nil }
        return seconds
    }

    private static func webURL(_ value: String?) -> URL? {
        guard let value, let url = URL(string: value),
            let scheme = url.scheme?.lowercased(),
            scheme == "https" || scheme == "http",
            url.host?.isEmpty == false
        else { return nil }
        return url
    }
}

private struct Envelope: Decodable {
    var message: Message
}

private struct Message: Decodable {
    var header: Header
    var body: Body?
}

private struct Header: Decodable {
    var statusCode: Int
    var region: String?

    private enum CodingKeys: String, CodingKey {
        case statusCode = "status_code"
        case region
        case country
        case requestedCountry = "requested_country"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        statusCode = try values.decode(Int.self, forKey: .statusCode)
        region =
            try values.decodeIfPresent(String.self, forKey: .region)
            ?? values.decodeIfPresent(String.self, forKey: .requestedCountry)
            ?? values.decodeIfPresent(String.self, forKey: .country)
    }
}

private struct Body: Decodable {
    var subtitle: Subtitle?
}

private struct Subtitle: Decodable {
    var restricted: FlexibleBoolean
    var subtitleBody: String
    var lyricsCopyright: String?
    var scriptTrackingURL: String?
    var pixelTrackingURL: String?

    private enum CodingKeys: String, CodingKey {
        case restricted
        case subtitleBody = "subtitle_body"
        case lyricsCopyright = "lyrics_copyright"
        case scriptTrackingURL = "script_tracking_url"
        case pixelTrackingURL = "pixel_tracking_url"
    }
}

private struct FlexibleBoolean: Decodable {
    var value: Bool

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if let boolean = try? value.decode(Bool.self) {
            self.value = boolean
        } else if let integer = try? value.decode(Int.self) {
            self.value = integer != 0
        } else {
            throw DecodingError.typeMismatch(
                Bool.self,
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "expected a boolean or integer restriction"))
        }
    }
}

private extension String {
    var nonEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
