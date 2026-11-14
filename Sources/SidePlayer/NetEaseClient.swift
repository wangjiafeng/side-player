import CryptoKit
import CommonCrypto
import Foundation
import Security

struct NetEasePlaylist: Identifiable, Hashable {
    let id: String
    let name: String
    let trackCount: Int
}

struct NetEaseStream {
    let url: URL
    let format: String
}

struct NetEaseSong: Identifiable, Hashable {
    let id: String
    let title: String
    let artist: String
    let year: String?
    let duration: TimeInterval
}

@MainActor
final class NetEaseClient: ObservableObject {
    static let shared = NetEaseClient()
    @Published private(set) var loginStatus = "尚未登录"
    @Published private(set) var isLoggedIn = false
    @Published private(set) var playlists: [NetEasePlaylist] = []
    @Published private(set) var errorMessage: String?

    private let session: URLSession
    private let keychainService = "com.zhengxinshushe.side-player.netease"
    private let keychainAccount = "cookie"

    func reportError(_ message: String?) { errorMessage = message }

    private init() {
        let configuration = URLSessionConfiguration.default
        configuration.httpCookieStorage = .shared
        configuration.httpCookieAcceptPolicy = .always
        session = URLSession(configuration: configuration)
        restoreCookies()
    }

    private static let website = URL(string: "https://music.163.com/")!
    static let loginPage = URL(string: "https://music.163.com/#/login")!

    func completeWebLogin(cookies: [HTTPCookie]) async throws {
        let valid = cookies.filter {
            let domain = $0.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
            return ["music.163.com", "163.com"].contains(domain)
                && $0.path == "/" && ($0.expiresDate.map { $0 > Date() } ?? true)
        }
        guard let token = valid.first(where: { $0.name == "MUSIC_U" && !$0.value.isEmpty }) else {
            throw ClientError.cookieMissing
        }
        let header = HTTPCookie.requestHeaderFields(with: [token])["Cookie"] ?? ""
        let uid = try await accountID(cookieHeader: header)
        let loadedPlaylists = try await fetchPlaylists(uid: uid, cookieHeader: header)
        try Task.checkCancellation()
        try saveCookie(header)
        setSessionCookies([token])
        isLoggedIn = true
        errorMessage = nil
        playlists = loadedPlaylists
        loginStatus = "已登录 · 找到 \(playlists.count) 个歌单"
    }

    private func accountID(cookieHeader: String? = nil) async throws -> Any {
        let account = try await eapi(path: "/api/w/nuser/account/get", payload: [:], cookieHeader: cookieHeader)
        let data = account["data"] as? [String: Any] ?? account
        let profile = data["profile"] as? [String: Any]
        let details = data["account"] as? [String: Any]
        guard let uid = (profile?["userId"] ?? details?["id"]) as? NSNumber, uid.int64Value > 0 else {
            throw ClientError.missingUserID
        }
        return uid
    }

    private func fetchPlaylists(uid: Any, cookieHeader: String? = nil) async throws -> [NetEasePlaylist] {
        let response = try await eapi(
            path: "/api/user/playlist",
            payload: ["uid": uid, "limit": 100, "offset": 0, "includeVideo": true],
            cookieHeader: cookieHeader
        )
        guard let rows = response["playlist"] as? [[String: Any]] else { throw ClientError.invalidResponse }
        return rows.compactMap { row in
            guard let id = row["id"] else { return nil }
            return NetEasePlaylist(id: String(describing: id), name: row["name"] as? String ?? "未命名歌单", trackCount: row["trackCount"] as? Int ?? 0)
        }
    }

    func loadPlaylists() async {
        do {
            let uid = try await accountID()
            playlists = try await fetchPlaylists(uid: uid)
            loginStatus = "已登录 · 找到 \(playlists.count) 个歌单"
        } catch {
            playlists = []
            errorMessage = "登录已完成，但读取歌单失败：\(error.localizedDescription)"
            loginStatus = "已登录，歌单读取失败"
        }
    }

    var playlistCacheScope: String? {
        guard isLoggedIn, let token = HTTPCookieStorage.shared.cookies(for: Self.website)?
            .first(where: { $0.name == "MUSIC_U" }) else { return nil }
        return SHA256.hash(data: Data(token.value.utf8)).description
    }

    func loadSongs(playlistIDs: Set<String>) async throws -> [NetEaseSong] {
        guard isLoggedIn else { return [] }
        var songRows: [[String: Any]] = []
        for playlistID in playlistIDs.sorted() {
            let response = try await eapi(path: "/api/v3/playlist/detail", payload: ["id": playlistID, "c": "[]", "t": "-1", "n": 100000, "s": "8"])
            if let playlist = response["playlist"] as? [String: Any],
               let songs = playlist["tracks"] as? [[String: Any]] {
                songRows.append(contentsOf: songs)
                let trackIDs = playlist["trackIds"] as? [[String: Any]] ?? []
                if trackIDs.count > songs.count {
                    let loadedIDs = Set(songs.compactMap { $0["id"] as? NSNumber })
                    let missingIDs = trackIDs.compactMap { $0["id"] as? NSNumber }.filter { !loadedIDs.contains($0) }
                    for batchStart in stride(from: 0, to: missingIDs.count, by: 100) {
                        let batch = Array(missingIDs[batchStart..<min(batchStart + 100, missingIDs.count)])
                        let entries = batch.map { ["id": $0, "v": 0] as [String: Any] }
                        let packed = try JSONSerialization.data(withJSONObject: entries, options: [.sortedKeys, .fragmentsAllowed])
                        let details = try await eapi(path: "/api/v3/song/detail", payload: ["c": String(data: packed, encoding: .utf8) ?? "[]", "rv": "true"])
                        songRows.append(contentsOf: details["songs"] as? [[String: Any]] ?? [])
                    }
                }
            }
        }
        return songRows.compactMap { row in
            guard let rawID = row["id"] as? NSNumber else { return nil }
            let artists = row["ar"] as? [[String: Any]] ?? row["artists"] as? [[String: Any]] ?? []
            let album = row["al"] as? [String: Any] ?? row["album"] as? [String: Any] ?? [:]
            let publishTime = album["publishTime"] as? Int64 ?? 0
            let year = publishTime > 0 ? String(Calendar.current.component(.year, from: Date(timeIntervalSince1970: TimeInterval(publishTime) / 1000))) : nil
            let duration = (row["dt"] as? Double ?? row["duration"] as? Double ?? 0) / 1000
            return NetEaseSong(id: rawID.stringValue, title: row["name"] as? String ?? "未知歌曲",
                              artist: artists.first?["name"] as? String ?? "未知歌手",
                              year: year, duration: duration)
        }
    }

    func lyrics(for songID: String) async throws -> String? {
        guard let id = Int64(songID) else { return nil }
        let response = try await eapi(path: "/api/song/lyric", payload: ["id": id, "lv": -1])
        return (response["lrc"] as? [String: Any])?["lyric"] as? String
    }

    func streamURL(for songID: String) async throws -> NetEaseStream {
        guard isLoggedIn, let id = Int64(songID) else { throw ClientError.missingUserID }
        for level in ["jymaster", "hires", "lossless"] {
            try Task.checkCancellation()
            do {
                if let stream = try await requestStream(id: id, level: level, format: "flac"),
                   stream.format == "flac" { return stream }
            } catch {
                if Task.isCancelled { throw error }
            }
        }
        for level in ["exhigh", "higher", "standard"] {
            try Task.checkCancellation()
            do {
                if let stream = try await requestStream(id: id, level: level, format: "mp3"),
                   stream.format == "mp3" { return stream }
            } catch {
                if Task.isCancelled { throw error }
            }
        }
        throw ClientError.streamUnavailable
    }

    private func requestStream(id: Int64, level: String, format: String) async throws -> NetEaseStream? {
        let response = try await eapi(path: "/api/song/enhance/player/url/v1",
                                     payload: ["ids": "[\(id)]", "level": level, "encodeType": format])
        guard let entries = response["data"] as? [[String: Any]],
              let entry = entries.first(where: { ($0["id"] as? NSNumber)?.int64Value == id }),
              entry["freeTrialInfo"] == nil || entry["freeTrialInfo"] is NSNull,
              let returnedFormat = entry["type"] as? String,
              let address = entry["url"] as? String,
              let url = URL(string: address), let host = url.host, !host.isEmpty,
              url.scheme == "http" || url.scheme == "https" else { return nil }
        return NetEaseStream(url: url, format: returnedFormat.lowercased())
    }

    func logout() {
        isLoggedIn = false
        playlists = []
        loginStatus = "尚未登录"
        setSessionCookies([])
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: keychainService, kSecAttrAccount as String: keychainAccount] as CFDictionary)
    }

    private func eapi(path: String, payload: [String: Any], cookieHeader: String? = nil) async throws -> [String: Any] {
        var body = payload
        body["verifyId"] = 1
        body["os"] = "OSX"
        let requestID = "\(Int(Date().timeIntervalSince1970 * 1000))_\(Int.random(in: 0...9999))"
        let headerData = try JSONSerialization.data(withJSONObject: ["os": "osx", "appver": "1.5.9", "requestId": requestID], options: [.sortedKeys])
        body["header"] = String(data: headerData, encoding: .utf8) ?? "{}"
        let jsonData = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys, .fragmentsAllowed])
        guard let json = String(data: jsonData, encoding: .utf8) else { throw ClientError.invalidResponse }
        let apiPath = path.hasPrefix("/api/") ? path : "/api" + path
        let digest = md5("nobody\(apiPath)use\(json)md5forencrypt")
        let source = Data("\(apiPath)-36cd479b6b5-\(json)-36cd479b6b5-\(digest)".utf8)
        let cipher = try aesECB(source, key: Data("e82ckenh8dichen8".utf8))
        let hex = cipher.map { String(format: "%02X", $0) }.joined()
        let endpointPath = apiPath.replacingOccurrences(of: "/api/", with: "/eapi/")
        guard let url = URL(string: "https://music.163.com\(endpointPath)") else { throw ClientError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")
        request.httpBody = Data("params=\(hex)".utf8)
        request.timeoutInterval = 15
        if let cookieHeader {
            request.httpShouldHandleCookies = false
            request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        }
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ClientError.server(http.statusCode, HTTPURLResponse.localizedString(forStatusCode: http.statusCode))
        }
        let decoded = (try? JSONSerialization.jsonObject(with: data)) ??
            (try? aesECBDecrypt(data, key: Data("e82ckenh8dichen8".utf8))).flatMap { try? JSONSerialization.jsonObject(with: $0) }
        guard let result = decoded as? [String: Any] else { throw ClientError.invalidResponse }
        if let code = result["code"] as? Int, code >= 400 {
            throw ClientError.server(code, result["message"] as? String ?? "请求失败")
        }
        return result
    }

    private func setSessionCookies(_ cookies: [HTTPCookie]) {
        let storage = HTTPCookieStorage.shared
        for cookie in storage.cookies(for: Self.website) ?? [] where cookie.name == "MUSIC_U" {
            storage.deleteCookie(cookie)
        }
        storage.setCookies(cookies, for: Self.website, mainDocumentURL: nil)
    }

    private func saveCookie(_ header: String) throws {
        let data = Data(header.utf8)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: keychainService, kSecAttrAccount as String: keychainAccount]
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecItemNotFound {
            var insert = query
            insert[kSecValueData as String] = data
            let status = SecItemAdd(insert as CFDictionary, nil)
            guard status == errSecSuccess else { throw ClientError.keychain(status) }
        } else if update != errSecSuccess { throw ClientError.keychain(update) }
    }

    private func restoreCookies() {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: keychainService, kSecAttrAccount as String: keychainAccount, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, let header = String(data: data, encoding: .utf8) else { return }
        let pairs = header.split(separator: ";").compactMap { pair -> (String, String)? in
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            return parts.count == 2 ? (parts[0].trimmingCharacters(in: .whitespaces), parts[1].trimmingCharacters(in: .whitespaces)) : nil
        }
        let cookies = pairs.compactMap { name, value in
            HTTPCookie(properties: [.domain: ".music.163.com", .path: "/", .name: name, .value: value, .secure: "TRUE"])
        }
        setSessionCookies(cookies)
        isLoggedIn = !cookies.isEmpty
        if isLoggedIn { loginStatus = "已恢复网易云登录状态"; Task { await loadPlaylists() } }
    }

    private func md5(_ string: String) -> String {
        let bytes = Array(string.utf8)
        var digest = [UInt8](repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH))
        _ = CC_MD5(bytes, CC_LONG(bytes.count), &digest)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func aesECB(_ input: Data, key: Data) throws -> Data {
        let padding = kCCBlockSizeAES128 - input.count % kCCBlockSizeAES128
        var padded = input
        padded.append(contentsOf: repeatElement(UInt8(padding), count: padding))
        var output = [UInt8](repeating: 0, count: padded.count)
        let capacity = output.count
        var count = 0
        let status = key.withUnsafeBytes { keyBytes in
            padded.withUnsafeBytes { inputBytes in
                output.withUnsafeMutableBytes { outputBytes in
                    CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode), keyBytes.baseAddress, key.count, nil, inputBytes.baseAddress, padded.count, outputBytes.baseAddress, capacity, &count)
                }
            }
        }
        guard status == kCCSuccess else { throw ClientError.encryption(status) }
        return Data(output.prefix(count))
    }

    private func aesECBDecrypt(_ input: Data, key: Data) throws -> Data {
        guard input.count.isMultiple(of: kCCBlockSizeAES128) else { throw ClientError.invalidResponse }
        var output = [UInt8](repeating: 0, count: input.count + kCCBlockSizeAES128)
        let capacity = output.count
        var count = 0
        let status = key.withUnsafeBytes { keyBytes in
            input.withUnsafeBytes { inputBytes in
                output.withUnsafeMutableBytes { outputBytes in
                    CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode | kCCOptionPKCS7Padding), keyBytes.baseAddress, key.count, nil, inputBytes.baseAddress, input.count, outputBytes.baseAddress, capacity, &count)
                }
            }
        }
        guard status == kCCSuccess else { throw ClientError.encryption(status) }
        return Data(output.prefix(count))
    }

    private enum ClientError: LocalizedError {
        case invalidURL, invalidResponse, missingUserID, cookieMissing, streamUnavailable
        case keychain(OSStatus), encryption(CCCryptorStatus), server(Int, String)
        var errorDescription: String? {
            switch self {
            case .invalidURL: "网易云音乐接口地址无效。"
            case .invalidResponse: "网易云音乐返回的数据无法识别。"
            case .missingUserID: "网易云未确认账号会话，请检查官网是否已登录。"
            case .streamUnavailable: "当前账号未取得此歌曲的完整 FLAC 无损播放地址。"
            case .cookieMissing: "尚未检测到官网登录，请在网页上登录后重试。"
            case .keychain(let status): "无法将登录凭证写入钥匙串（\(status)）。"
            case .encryption(let status): "网易云请求加密失败（\(status)）。"
            case .server(let code, let message): "网易云音乐接口错误（\(code)）：\(message)"
            }
        }
    }
}
