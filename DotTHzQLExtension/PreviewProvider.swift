import Cocoa
import Quartz
import HDF5Kit
import UniformTypeIdentifiers

final class PreviewProvider: QLPreviewProvider, QLPreviewingController {
    func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {
        let fileURL = request.fileURL
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let fileSummary = summarizeHDF5File(at: fileURL)
        let metadata = fileSummary.metadata ?? "Could not read metadata."

        let fileName = fileURL.lastPathComponent
        let fileExtension = fileURL.pathExtension.isEmpty ? "HDF5" : fileURL.pathExtension.uppercased()
        let fileSize = (fileAttributes[.size] as? NSNumber)?.int64Value ?? 0
        let fileCreationDate = fileAttributes[.creationDate] as? Date
        let fileModificationDate = fileAttributes[.modificationDate] as? Date

        let byteFormatter = ByteCountFormatter()
        byteFormatter.countStyle = .file
        let readableSize = byteFormatter.string(fromByteCount: fileSize)

        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .short

        let createdStr = fileCreationDate.map { dateFormatter.string(from: $0) } ?? "Unknown"
        let modifiedStr = fileModificationDate.map { dateFormatter.string(from: $0) } ?? "Unknown"

        let previewAsset = previewAsset(for: fileURL)

        let html = makeHTML(
            fileName: escapeHTML(fileName),
            fileExtension: escapeHTML(fileExtension),
            readableSize: escapeHTML(readableSize),
            createdStr: escapeHTML(createdStr),
            modifiedStr: escapeHTML(modifiedStr),
            structureSummary: escapeHTML(fileSummary.structureSummary),
            metadata: escapeHTML(metadata),
            previewAsset: previewAsset
        )

        return QLPreviewReply(dataOfContentType: .html, contentSize: CGSize(width: 860, height: 560)) { _ in
            html.data(using: .utf8) ?? Data()
        }
    }

    private func makeHTML(
        fileName: String,
        fileExtension: String,
        readableSize: String,
        createdStr: String,
        modifiedStr: String,
        structureSummary: String,
        metadata: String,
        previewAsset: PreviewAsset
    ) -> String {
        let previewImage = """
        <img class="preview-image" src="data:image/png;base64,\(previewAsset.base64PNG)" width="\(Int(previewAsset.displaySize.width))" height="\(Int(previewAsset.displaySize.height))" alt="" />
        """

        let previewCaption = previewAsset.isRenderedDataset ? "Rendered dataset preview" : "DotTHz file"

        return """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="utf-8" />
            <meta name="viewport" content="width=device-width, initial-scale=1" />
            <style>
                :root {
                    color-scheme: light dark;
                    --window-bg: #f4f4f6;
                    --panel-bg: rgba(255, 255, 255, 0.82);
                    --panel-border: rgba(28, 28, 30, 0.08);
                    --section-bg: rgba(255, 255, 255, 0.6);
                    --text-primary: #1d1d1f;
                    --text-secondary: rgba(60, 60, 67, 0.78);
                    --divider: rgba(60, 60, 67, 0.16);
                    --shadow: 0 18px 44px rgba(17, 24, 39, 0.12);
                }

                @media (prefers-color-scheme: dark) {
                    :root {
                        --window-bg: #1c1c1e;
                        --panel-bg: rgba(44, 44, 46, 0.82);
                        --panel-border: rgba(255, 255, 255, 0.08);
                        --section-bg: rgba(58, 58, 60, 0.55);
                        --text-primary: rgba(255, 255, 255, 0.96);
                        --text-secondary: rgba(235, 235, 245, 0.66);
                        --divider: rgba(255, 255, 255, 0.1);
                        --shadow: 0 24px 54px rgba(0, 0, 0, 0.35);
                    }
                }

                * {
                    box-sizing: border-box;
                }

                html, body {
                    margin: 0;
                    height: 100%;
                    background:
                        radial-gradient(circle at top left, rgba(122, 162, 255, 0.16), transparent 34%),
                        radial-gradient(circle at bottom right, rgba(94, 196, 160, 0.14), transparent 30%),
                        var(--window-bg);
                    color: var(--text-primary);
                    font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
                }

                body {
                    padding: 18px;
                }

                .shell {
                    display: grid;
                    grid-template-columns: minmax(280px, 1.05fr) minmax(320px, 1fr);
                    gap: 18px;
                    height: 100%;
                }

                .panel {
                    min-height: 0;
                    border-radius: 20px;
                    border: 1px solid var(--panel-border);
                    background: var(--panel-bg);
                    box-shadow: var(--shadow);
                    backdrop-filter: blur(26px);
                    -webkit-backdrop-filter: blur(26px);
                    overflow: hidden;
                }

                .preview-panel {
                    display: flex;
                    flex-direction: column;
                    justify-content: center;
                    align-items: center;
                    gap: 14px;
                    padding: 24px;
                    background:
                        linear-gradient(180deg, rgba(255, 255, 255, 0.22), rgba(255, 255, 255, 0.08)),
                        var(--panel-bg);
                }

                .preview-stage {
                    width: 100%;
                    height: 100%;
                    min-height: 0;
                    display: flex;
                    align-items: center;
                    justify-content: center;
                    padding: 18px;
                    border-radius: 18px;
                    border: 1px solid var(--divider);
                    background:
                        linear-gradient(180deg, rgba(255, 255, 255, 0.28), rgba(255, 255, 255, 0.14)),
                        var(--section-bg);
                }

                .preview-image {
                    max-width: 100%;
                    max-height: 100%;
                    object-fit: contain;
                    image-rendering: auto;
                    filter: drop-shadow(0 14px 28px rgba(0, 0, 0, 0.16));
                }

                .preview-caption {
                    font-size: 12px;
                    color: var(--text-secondary);
                }

                .inspector {
                    display: flex;
                    flex-direction: column;
                    min-height: 0;
                }

                .header {
                    padding: 22px 22px 18px;
                    border-bottom: 1px solid var(--divider);
                }

                .eyebrow {
                    margin: 0 0 8px;
                    font-size: 11px;
                    font-weight: 700;
                    letter-spacing: 0.08em;
                    text-transform: uppercase;
                    color: var(--text-secondary);
                }

                h1 {
                    margin: 0;
                    font-size: 24px;
                    line-height: 1.2;
                    letter-spacing: -0.03em;
                    word-break: break-word;
                }

                .subheadline {
                    margin-top: 8px;
                    font-size: 13px;
                    color: var(--text-secondary);
                }

                .facts {
                    display: grid;
                    grid-template-columns: repeat(2, minmax(0, 1fr));
                    gap: 10px;
                    padding: 18px 22px;
                    border-bottom: 1px solid var(--divider);
                }

                .fact {
                    padding: 12px 14px;
                    border-radius: 14px;
                    background: var(--section-bg);
                    border: 1px solid var(--panel-border);
                }

                .fact-label {
                    display: block;
                    margin-bottom: 5px;
                    font-size: 11px;
                    font-weight: 600;
                    letter-spacing: 0.03em;
                    text-transform: uppercase;
                    color: var(--text-secondary);
                }

                .fact-value {
                    font-size: 13px;
                    line-height: 1.35;
                    word-break: break-word;
                }

                .metadata-section {
                    display: flex;
                    flex-direction: column;
                    min-height: 0;
                    padding: 18px 22px 22px;
                    gap: 10px;
                }

                .metadata-title {
                    font-size: 13px;
                    font-weight: 600;
                    color: var(--text-secondary);
                }

                .metadata {
                    flex: 1;
                    min-height: 0;
                    margin: 0;
                    padding: 14px 16px;
                    overflow: auto;
                    white-space: pre-wrap;
                    word-break: break-word;
                    border-radius: 16px;
                    border: 1px solid var(--divider);
                    background: var(--section-bg);
                    font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
                    font-size: 12px;
                    line-height: 1.55;
                    color: var(--text-primary);
                }

                .metadata::-webkit-scrollbar {
                    width: 10px;
                }

                .metadata::-webkit-scrollbar-thumb {
                    background: rgba(128, 128, 128, 0.42);
                    border-radius: 999px;
                    border: 2px solid transparent;
                    background-clip: content-box;
                }

                @media (max-width: 740px) {
                    body {
                        padding: 12px;
                    }

                    .shell {
                        grid-template-columns: 1fr;
                    }

                    .preview-panel {
                        min-height: 220px;
                    }
                }
            </style>
        </head>
        <body>
            <div class="shell">
                <section class="panel preview-panel">
                    <div class="preview-stage">
                        \(previewImage)
                    </div>
                    <div class="preview-caption">\(previewCaption)</div>
                </section>
                <section class="panel inspector">
                    <header class="header">
                        <p class="eyebrow">Quick Look</p>
                        <h1>\(fileName)</h1>
                    </header>
                    <div class="facts">
                        <div class="fact">
                            <span class="fact-label">Created</span>
                            <span class="fact-value">\(createdStr)</span>
                        </div>
                        <div class="fact">
                            <span class="fact-label">Modified</span>
                            <span class="fact-value">\(modifiedStr)</span>
                        </div>
                        <div class="fact">
                            <span class="fact-label">Size</span>
                            <span class="fact-value">\(readableSize)</span>
                        </div>
                        <div class="fact">
                            <span class="fact-label">Structure</span>
                            <span class="fact-value">\(structureSummary)</span>
                        </div>
                    </div>
                    <div class="metadata-section">
                        <div class="metadata-title">Contents</div>
                        <pre class="metadata">\(metadata)</pre>
                    </div>
                </section>
            </div>
        </body>
        </html>
        """
    }

    private func previewAsset(for fileURL: URL) -> PreviewAsset {
        if let renderedPreview = renderDatasetPreview(from: fileURL) {
            return renderedPreview
        }

        let fallbackSize = NSSize(width: 240, height: 240)
        let icon = NSWorkspace.shared.icon(forFile: fileURL.path)
        icon.size = fallbackSize

        guard
            let cgImage = icon.cgImage(forProposedRect: nil, context: nil, hints: nil),
            let pngData = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
        else {
            return PreviewAsset(base64PNG: "", displaySize: fallbackSize, isRenderedDataset: false)
        }

        return PreviewAsset(
            base64PNG: pngData.base64EncodedString(),
            displaySize: fallbackSize,
            isRenderedDataset: false
        )
    }

    private func renderDatasetPreview(from fileURL: URL) -> PreviewAsset? {
        guard let file = File.open(fileURL.path, mode: .readOnly) else {
            return nil
        }

        for groupName in file.getGroupNames() ?? [] {
            guard let group = file.openGroup(groupName) else {
                continue
            }

            for datasetName in group.objectNames() {
                guard let dataset = group.openDataset(datasetName) else {
                    continue
                }

                let dims = dataset.space.dims
                guard dims.count == 3 else {
                    continue
                }

                do {
                    let height = Int(dims[0])
                    let width = Int(dims[1])
                    let channels = Int(dims[2])
                    let elementCount = height * width * channels

                    guard height > 0, width > 0, channels > 0 else {
                        continue
                    }

                    var buffer = [Float](repeating: 0, count: elementCount)
                    try dataset.read(into: &buffer, type: NativeType.float)

                    var grayscalePixels = [UInt8](repeating: 0, count: height * width)
                    var maxValue: Float = 0

                    for y in 0..<height {
                        for x in 0..<width {
                            let pixelOffset = (y * width + x) * channels
                            var magnitude: Float = 0

                            for channel in 0..<channels {
                                let value = buffer[pixelOffset + channel]
                                magnitude += value * value
                            }

                            let normalizedMagnitude = sqrt(magnitude)
                            maxValue = max(maxValue, normalizedMagnitude)
                            buffer[y * width + x] = normalizedMagnitude
                        }
                    }

                    let safeMax = max(maxValue, .leastNonzeroMagnitude)
                    for index in 0..<(height * width) {
                        let normalized = min(1, max(0, buffer[index] / safeMax))
                        grayscalePixels[index] = UInt8(normalized * 255)
                    }

                    let bytesPerRow = width
                    let colorSpace = CGColorSpaceCreateDeviceGray()
                    let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue)

                    guard let provider = CGDataProvider(data: Data(grayscalePixels) as CFData) else {
                        continue
                    }

                    guard let cgImage = CGImage(
                        width: width,
                        height: height,
                        bitsPerComponent: 8,
                        bitsPerPixel: 8,
                        bytesPerRow: bytesPerRow,
                        space: colorSpace,
                        bitmapInfo: bitmapInfo,
                        provider: provider,
                        decode: nil,
                        shouldInterpolate: false,
                        intent: .defaultIntent
                    ) else {
                        continue
                    }

                    let displayWidth: CGFloat = 360
                    let displayHeight = max(180, displayWidth * CGFloat(height) / CGFloat(width))
                    let displaySize = NSSize(width: displayWidth, height: displayHeight)
                    let image = NSImage(cgImage: cgImage, size: displaySize)

                    guard
                        let tiffData = image.tiffRepresentation,
                        let bitmapRep = NSBitmapImageRep(data: tiffData),
                        let pngData = bitmapRep.representation(using: .png, properties: [:])
                    else {
                        continue
                    }

                    return PreviewAsset(
                        base64PNG: pngData.base64EncodedString(),
                        displaySize: displaySize,
                        isRenderedDataset: true
                    )
                } catch {
                    continue
                }
            }
        }

        return nil
    }

    private func summarizeHDF5File(at fileURL: URL) -> FileSummary {
        guard let file = File.open(fileURL.path, mode: .readOnly) else {
            return FileSummary(metadata: nil, groupCount: 0, datasetCount: 0)
        }

        var sections: [String] = []
        let groups = file.getGroupNames() ?? []
        var datasetCount = 0

        if groups.isEmpty {
            return FileSummary(metadata: "No groups found.", groupCount: 0, datasetCount: 0)
        }

        for groupName in groups {
            var lines = ["\(groupName)"]

            guard let group = file.openGroup(groupName) else {
                lines.append("  Failed to open group.")
                sections.append(lines.joined(separator: "\n"))
                continue
            }

            let dsDescriptions = descriptions(for: "dsDescription", in: group)
            let mdDescriptions = descriptions(for: "mdDescription", in: group)

            let datasets = group.objectNames()
            datasetCount += datasets.count
            if datasets.isEmpty {
                lines.append("  Datasets: none")
            } else {
                lines.append("  Datasets:")
                for datasetName in datasets {
                    let label = resolvedLabel(for: datasetName, prefix: "ds", descriptions: dsDescriptions)
                    let shape = shapeDescription(for: datasetName, in: group)
                    lines.append("    • \(label)\(shape)")
                }
            }

            let attributeNames = group.attributeNames().filter { !["dsDescription", "mdDescription"].contains($0) }
            if attributeNames.isEmpty {
                lines.append("  Metadata: none")
            } else {
                lines.append("  Metadata:")
                for attributeName in attributeNames {
                    let label = resolvedLabel(for: attributeName, prefix: "md", descriptions: mdDescriptions)
                    let value = attributeValue(for: attributeName, in: group)
                    lines.append("    - \(label): \(value)")
                }
            }

            sections.append(lines.joined(separator: "\n"))
        }

        return FileSummary(
            metadata: sections.joined(separator: "\n\n"),
            groupCount: groups.count,
            datasetCount: datasetCount
        )
    }

    private func descriptions(for attributeName: String, in group: Group) -> [String] {
        guard
            let attribute = group.openStringAttribute(attributeName),
            let rawList = try? attribute.read(),
            let joined = rawList.first
        else {
            return []
        }

        return joined
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func resolvedLabel(for rawName: String, prefix: String, descriptions: [String]) -> String {
        guard rawName.hasPrefix(prefix) else {
            return rawName
        }

        let suffix = rawName.dropFirst(prefix.count)
        guard let oneBasedIndex = Int(suffix) else {
            return rawName
        }

        let index = oneBasedIndex - 1
        guard descriptions.indices.contains(index) else {
            return rawName
        }

        return descriptions[index]
    }

    private func shapeDescription(for datasetName: String, in group: Group) -> String {
        guard let dataset = group.openDataset(datasetName) else {
            return ""
        }

        let dims = dataset.space.dims
        guard !dims.isEmpty else {
            return ""
        }

        let joined = dims.map(String.init).joined(separator: " × ")
        return " (\(joined))"
    }

    private func attributeValue(for attributeName: String, in group: Group) -> String {
        if let attribute = group.openDoubleAttribute(attributeName), let values = try? attribute.read() {
            return cleanArrayString(String(describing: values))
        }

        if let attribute = group.openStringAttribute(attributeName), let values = try? attribute.read() {
            return cleanArrayString(String(describing: values))
        }

        return "<unreadable>"
    }

    private func cleanArrayString(_ value: String) -> String {
        value
            .replacingOccurrences(of: "[", with: "")
            .replacingOccurrences(of: "]", with: "")
    }

    private func escapeHTML(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}

private struct PreviewAsset {
    let base64PNG: String
    let displaySize: NSSize
    let isRenderedDataset: Bool
}

private struct FileSummary {
    let metadata: String?
    let groupCount: Int
    let datasetCount: Int

    var structureSummary: String {
        "\(groupCount) \(groupCount == 1 ? "group" : "groups"), \(datasetCount) \(datasetCount == 1 ? "dataset" : "datasets")"
    }
}
