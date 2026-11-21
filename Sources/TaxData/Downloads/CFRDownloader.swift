import Foundation

public struct CFRVolumeSpec: Sendable, Hashable, Identifiable {
    public var id: Int { volume }
    public var volume: Int
    public var scope: String
    public var topics: String
    public var courses: [String]

    public var isCoreLLMVolume: Bool {
        !courses.isEmpty
    }

    public func filename(year: Int) -> String {
        "CFR-\(year)-title26-vol\(volume).xml"
    }

    public func downloadURL(year: Int) -> URL {
        URL(string: "https://www.govinfo.gov/bulkdata/CFR/\(year)/title-26/CFR-\(year)-title26-vol\(volume).xml")!
    }
}

public enum CFRCatalog {
    public static let title26Volumes: [CFRVolumeSpec] = [
        .init(volume: 1,  scope: "Part 1 (§§ 1.0-1 – 1.60)",       topics: "Rates, Credits, Threshold Definitions",                   courses: ["Fed Income (640)"]),
        .init(volume: 2,  scope: "Part 1 (§§ 1.61 – 1.139)",       topics: "Gross Income, Inclusions & Exclusions",                   courses: ["Fed Income (640)"]),
        .init(volume: 3,  scope: "Part 1 (§§ 1.140 – 1.169)",      topics: "Tax-Exempt Bonds, § 162 Business Expenses, Depreciation", courses: ["Fed Income (640)"]),
        .init(volume: 4,  scope: "Part 1 (§§ 1.170 – 1.300)",      topics: "Deductions, § 199A, § 263A, § 267 Related Parties",       courses: ["Fed Income (640)", "Corporate (610)"]),
        .init(volume: 5,  scope: "Part 1 (§§ 1.301 – 1.400)",      topics: "Subchapter C: Distributions, Redemptions, § 351, Reorgs", courses: ["Corporate (610)"]),
        .init(volume: 6,  scope: "Part 1 (§§ 1.401 – 1.409)",      topics: "Qualified Pension, Profit-Sharing & Stock Bonus Plans",   courses: []),
        .init(volume: 7,  scope: "Part 1 (§§ 1.410 – 1.440)",      topics: "Employee Benefit Vesting, Funding & Deferred Comp",       courses: []),
        .init(volume: 8,  scope: "Part 1 (§§ 1.441 – 1.500)",      topics: "Taxable Years, Accounting Methods, § 482 Transfer Pricing", courses: ["Fed Income (640)", "International (670)"]),
        .init(volume: 9,  scope: "Part 1 (§§ 1.501 – 1.640)",      topics: "Exempt Organizations, UBIT & Accumulated Earnings",       courses: []),
        .init(volume: 10, scope: "Part 1 (§§ 1.641 – 1.850)",      topics: "Subchapter K Partnerships (§§ 1.701–1.761), Trusts",      courses: ["Partnership (620)"]),
        .init(volume: 11, scope: "Part 1 (§§ 1.851 – 1.907)",      topics: "Source Rules, Inbound FDAP/ECI, § 897 FIRPTA, FTC",       courses: ["International (670)"]),
        .init(volume: 12, scope: "Part 1 (§§ 1.908 – 1.1000)",     topics: "CFCs, Subpart F, GILTI, § 956, § 985 Foreign Currency",   courses: ["International (670)"]),
        .init(volume: 13, scope: "Part 1 (§§ 1.1001 – 1.1400)",    topics: "Gain/Loss Realization, Basis, § 1031, Capital Gains, S Corps", courses: ["Fed Income (640)", "Corporate (610)", "Partnership (620)"]),
        .init(volume: 14, scope: "Part 1 (§§ 1.1401 – 1.1550)",    topics: "Withholding (§§ 1441–1474 FATCA) & § 1502 Consolidated", courses: ["International (670)", "Corporate (610)"]),
        .init(volume: 15, scope: "Part 1 (§ 1.1551 – End Part 1)", topics: "Affiliated Groups & Income Tax Return/Reporting Regs",    courses: ["Corporate (610)", "Procedure (675)"]),
        .init(volume: 16, scope: "Parts 2 – 29",                   topics: "Estate & Gift Tax Regulations",                           courses: []),
        .init(volume: 17, scope: "Parts 30 – 39",                  topics: "Employment Taxes & Collection at Source",                 courses: []),
        .init(volume: 18, scope: "Parts 40 – 49",                  topics: "Manufacturers & Facilities Excise Taxes",                 courses: []),
        .init(volume: 19, scope: "Parts 50 – 299",                 topics: "Regulatory & Special Excise Taxes",                       courses: []),
        .init(volume: 20, scope: "Parts 300 – 499",                topics: "Part 301 Procedure & Admin, § 301.7701-3 Check-the-Box", courses: ["Procedure (675)", "Partnership (620)", "Corporate (610)", "International (670)"]),
        .init(volume: 21, scope: "Parts 500 – 599",                topics: "Tax Conventions & Treaty Regulations",                    courses: ["International (670)"]),
        .init(volume: 22, scope: "Part 600 – End",                 topics: "Part 601 IRS Procedural Rules (Appeals, Rulings, Closing)", courses: ["Procedure (675)"]),
    ]

    public static let olrcTitle26XMLZipURL = URL(string: "https://uscode.house.gov/download/releasepoints/us/pl/119/142/xml_usc26@119-142.zip")
}

public enum VolumeDownloadError: Error, LocalizedError, Sendable {
    case httpError(statusCode: Int, url: URL)
    case emptyPayload(URL)

    public var errorDescription: String? {
        switch self {
        case .httpError(let status, let url):
            return "HTTP \(status) downloading \(url.lastPathComponent)"
        case .emptyPayload(let url):
            return "Downloaded empty file from \(url.lastPathComponent)"
        }
    }
}

public actor CorpusIngestor {
    private let database: TaxDatabase
    private let session: URLSession

    public init(database: TaxDatabase = .shared, session: URLSession = .shared) {
        self.database = database
        self.session = session
    }

    public func detectLatestCFRYear() async -> Int {
        for candidateYear in [2026, 2025, 2024] {
            var request = URLRequest(url: URL(string: "https://www.govinfo.gov/bulkdata/json/CFR/\(candidateYear)/title-26")!)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.timeoutInterval = 8
            if let (_, response) = try? await session.data(for: request),
               let http = response as? HTTPURLResponse,
               (200..<300).contains(http.statusCode) {
                return candidateYear
            }
        }
        return 2025
    }

    public func downloadAndImportCFRVolume(
        _ spec: CFRVolumeSpec,
        year: Int? = nil
    ) async throws -> ImportedSourceInfo {
        let targetYear: Int
        if let year {
            targetYear = year
        } else {
            targetYear = await detectLatestCFRYear()
        }

        let candidateYears = Array(Set([targetYear, 2025, 2024])).sorted(by: >)
        var lastError: Error?

        for yr in candidateYears {
            let remoteURL = spec.downloadURL(year: yr)
            do {
                let (tempURL, response) = try await session.download(from: remoteURL)
                guard let http = response as? HTTPURLResponse else { continue }
                guard (200..<300).contains(http.statusCode) else {
                    lastError = VolumeDownloadError.httpError(statusCode: http.statusCode, url: remoteURL)
                    continue
                }

                let destURL = TaxDatabase.volumesDirectoryURL().appendingPathComponent(spec.filename(year: yr))
                if FileManager.default.fileExists(atPath: destURL.path) {
                    try FileManager.default.removeItem(at: destURL)
                }
                try FileManager.default.moveItem(at: tempURL, to: destURL)

                let db = self.database
                return try await Task.detached(priority: .userInitiated) {
                    try db.importXMLFile(at: destURL, sourceID: spec.filename(year: yr))
                }.value
            } catch {
                lastError = error
            }
        }

        throw lastError ?? VolumeDownloadError.emptyPayload(spec.downloadURL(year: targetYear))
    }

    public func importLocalPath(_ url: URL) async throws -> [ImportedSourceInfo] {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed { url.stopAccessingSecurityScopedResource() }
        }

        let xmlURLs = Self.collectXMLFiles(at: url)
        let db = self.database
        return try await Task.detached(priority: .userInitiated) {
            var imported: [ImportedSourceInfo] = []
            for fileURL in xmlURLs {
                let destURL = TaxDatabase.volumesDirectoryURL().appendingPathComponent(fileURL.lastPathComponent)
                let targetURL: URL
                if fileURL.standardizedFileURL != destURL.standardizedFileURL {
                    try? FileManager.default.removeItem(at: destURL)
                    if (try? FileManager.default.copyItem(at: fileURL, to: destURL)) != nil {
                        targetURL = destURL
                    } else {
                        targetURL = fileURL
                    }
                } else {
                    targetURL = fileURL
                }
                let info = try db.importXMLFile(at: targetURL, sourceID: fileURL.lastPathComponent)
                imported.append(info)
            }
            return imported
        }.value
    }

    /// Discovers existing XML files in `Application Support/TaxCodeReader/Volumes/` or the repo's `Data/` folder on first launch.
    public static func discoverBootstrapXMLFiles() -> [URL] {
        var urls: [URL] = []
        var seenNames = Set<String>()

        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Downloads
            .deletingLastPathComponent() // TaxData
            .deletingLastPathComponent() // Sources
            .deletingLastPathComponent() // Repo root

        let candidateRoots: [URL] = [
            TaxDatabase.volumesDirectoryURL(),
            repoRoot.appendingPathComponent("Data", isDirectory: true),
        ]

        let ircFilenames: Set<String> = ["title26.xml", "usc26.xml", "tax-code.xml"]

        for root in candidateRoots where FileManager.default.fileExists(atPath: root.path) {
            for file in collectXMLFiles(at: root) {
                let lowerName = file.lastPathComponent.lowercased()
                let canonicalKey = ircFilenames.contains(lowerName) ? "irc-title26" : lowerName
                if seenNames.insert(canonicalKey).inserted {
                    urls.append(file)
                }
            }
        }
        return urls
    }

    private static func collectXMLFiles(at url: URL) -> [URL] {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return [] }
        if !isDir.boolValue {
            return url.pathExtension.lowercased() == "xml" ? [url] : []
        }

        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var files: [URL] = []
        for case let fileURL as URL in enumerator where fileURL.pathExtension.lowercased() == "xml" {
            files.append(fileURL)
        }
        return files.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
