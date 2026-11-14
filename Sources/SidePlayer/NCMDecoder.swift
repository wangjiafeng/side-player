import CommonCrypto
import Foundation

enum NCMDecodeError: LocalizedError {
    case invalidHeader
    case truncatedFile
    case invalidKey
    case cannotCreateOutput

    var errorDescription: String? {
        switch self {
        case .invalidHeader: "这不是有效的 NCM 文件。"
        case .truncatedFile: "NCM 文件内容不完整。"
        case .invalidKey: "NCM 音频密钥解密失败。"
        case .cannotCreateOutput: "无法创建临时解密音频文件。"
        }
    }
}

struct NCMMetadata {
    let title: String?
    let artist: String?
    let format: String?
}

enum NCMDecoder {
    private static let signature = Data("CTENFDAM".utf8)
    private static let coreKey = Data(hex: "687A4852416D736F356B496E62617857")
    private static let metadataKey = Data(hex: "2331346C6A6B5F215C5D2630553C2728")

    static func readMetadata(url: URL) -> NCMMetadata? {
        guard let input = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        var cursor = 0
        guard (try? readRequired(input, at: &cursor, count: 8)) == signature,
              (try? readRequired(input, at: &cursor, count: 2)) != nil,
              let keyLength = try? readUInt32(input, at: &cursor),
              (try? readRequired(input, at: &cursor, count: keyLength)) != nil,
              let metadataLength = try? readUInt32(input, at: &cursor),
              let encrypted = try? readRequired(input, at: &cursor, count: metadataLength)
        else { return nil }
        return parseMetadata(encrypted)
    }

    /// 解密到临时文件，避免改写用户的原始 NCM 文件。
    static func decode(url: URL) throws -> URL {
        let input = try Data(contentsOf: url, options: .mappedIfSafe)
        var cursor = 0
        guard try readRequired(input, at: &cursor, count: 8) == signature else { throw NCMDecodeError.invalidHeader }
        _ = try readRequired(input, at: &cursor, count: 2)

        let keyLength = try readUInt32(input, at: &cursor)
        var encryptedKey = try readRequired(input, at: &cursor, count: keyLength)
        for index in encryptedKey.indices { encryptedKey[index] ^= 0x64 }
        let decryptedKey = try aesECBDecrypt(encryptedKey, key: coreKey)
        let prefix = Data("neteasecloudmusic".utf8)
        guard decryptedKey.starts(with: prefix), decryptedKey.count > prefix.count else { throw NCMDecodeError.invalidKey }
        let musicKey = Data(decryptedKey.dropFirst(prefix.count))
        let keyBox = makeKeyBox(from: musicKey)

        let metadataLength = try readUInt32(input, at: &cursor)
        let encryptedMetadata = try readRequired(input, at: &cursor, count: metadataLength)
        let metadata = parseMetadata(encryptedMetadata)
        _ = try readRequired(input, at: &cursor, count: 4) // CRC32
        _ = try readRequired(input, at: &cursor, count: 5) // reserved bytes
        let imageLength = try readUInt32(input, at: &cursor)
        _ = try readRequired(input, at: &cursor, count: imageLength)
        guard cursor < input.count else { throw NCMDecodeError.truncatedFile }

        var audio = Data(input[cursor...])
        audio.withUnsafeMutableBytes { buffer in
            guard let bytes = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            for index in 0..<buffer.count {
                let j = (index + 1) & 0xff
                let a = Int(keyBox[j])
                let b = Int(keyBox[(a + j) & 0xff])
                bytes[index] ^= keyBox[(a + b) & 0xff]
            }
        }

        let declaredFormat = metadata?.format?.lowercased()
        let ext = ["mp3", "flac", "m4a", "wav", "aac", "aiff", "ogg", "opus"].contains(declaredFormat ?? "")
            ? declaredFormat!
            : outputExtension(for: audio)
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("side-player-\(UUID().uuidString).\(ext)")
        guard FileManager.default.createFile(atPath: destination.path, contents: audio) else {
            throw NCMDecodeError.cannotCreateOutput
        }
        return destination
    }

    private static func parseMetadata(_ encrypted: Data) -> NCMMetadata? {
        var xored = Data(encrypted)
        for index in xored.indices { xored[index] ^= 0x63 }
        guard xored.count > 22,
              let base64 = Data(base64Encoded: xored.dropFirst(22)),
              let decrypted = try? aesECBDecrypt(base64, key: metadataKey),
              decrypted.starts(with: Data("music:".utf8)),
              let json = try? JSONSerialization.jsonObject(with: decrypted.dropFirst(6)),
              let object = json as? [String: Any]
        else { return nil }
        let artists = object["artist"] as? [[Any]]
        let artist = artists?.first?.first as? String
        return NCMMetadata(title: object["musicName"] as? String, artist: artist, format: object["format"] as? String)
    }

    private static func makeKeyBox(from key: Data) -> [UInt8] {
        var box = Array(UInt8.min...UInt8.max)
        var lastByte = 0
        var keyOffset = 0
        let keyBytes = Array(key)
        for index in 0..<256 {
            let swap = Int(box[index])
            let c = (swap + lastByte + Int(keyBytes[keyOffset])) & 0xff
            keyOffset = (keyOffset + 1) % keyBytes.count
            box[index] = box[c]
            box[c] = UInt8(swap)
            lastByte = c
        }
        return box
    }

    private static func outputExtension(for data: Data) -> String {
        if data.starts(with: Data("fLaC".utf8)) { return "flac" }
        if data.starts(with: Data("ID3".utf8)) { return "mp3" }
        if data.starts(with: Data("OggS".utf8)) { return "ogg" }
        if data.count > 8, data[4..<8] == Data("ftyp".utf8) { return "m4a" }
        if data.count > 2, data[0] == 0xff, data[1] & 0xf6 == 0xf0 { return "aac" }
        if data.starts(with: Data("RIFF".utf8)) { return "wav" }
        return "mp3"
    }

    private static func aesECBDecrypt(_ data: Data, key: Data) throws -> Data {
        guard data.count % kCCBlockSizeAES128 == 0 else { throw NCMDecodeError.invalidKey }
        var output = [UInt8](repeating: 0, count: data.count + kCCBlockSizeAES128)
        let outputCapacity = output.count
        var outputCount = 0
        let status = key.withUnsafeBytes { keyBytes in
            data.withUnsafeBytes { inputBytes in
                output.withUnsafeMutableBytes { outputBytes in
                    CCCrypt(
                        CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionPKCS7Padding | kCCOptionECBMode),
                        keyBytes.baseAddress, key.count, nil,
                        inputBytes.baseAddress, data.count,
                        outputBytes.baseAddress, outputCapacity, &outputCount
                    )
                }
            }
        }
        guard status == kCCSuccess else { throw NCMDecodeError.invalidKey }
        return Data(output.prefix(outputCount))
    }

    private static func readUInt32(_ data: Data, at cursor: inout Int) throws -> Int {
        let bytes = try readRequired(data, at: &cursor, count: 4)
        return Int(bytes[0]) | Int(bytes[1]) << 8 | Int(bytes[2]) << 16 | Int(bytes[3]) << 24
    }

    private static func readRequired(_ data: Data, at cursor: inout Int, count: Int) throws -> Data {
        guard count >= 0, cursor <= data.count, count <= data.count - cursor else { throw NCMDecodeError.truncatedFile }
        return read(data, at: &cursor, count: count)
    }

    private static func read(_ data: Data, at cursor: inout Int, count: Int) -> Data {
        defer { cursor += count }
        return data.subdata(in: cursor..<(cursor + count))
    }
}

private extension Data {
    init(hex: String) {
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index..<next], radix: 16) ?? 0)
            index = next
        }
        self.init(bytes)
    }
}
