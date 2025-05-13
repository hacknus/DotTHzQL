import Cocoa
import Quartz
import HDF5Kit
import UniformTypeIdentifiers
import Accelerate

class PreviewProvider: QLPreviewProvider, QLPreviewingController {
    
    func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {
        let fileURL = request.fileURL
        let metadata = extractHDF5Metadata(from: fileURL) ?? "Could not read metadata"

        // File details
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let fileName = fileURL.lastPathComponent
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

        let iconBase64: String = {
            print("🔍 Attempting to open HDF5 file at: \(fileURL.path)")
            if let file = File.open(fileURL.path, mode: .readOnly) {
                for groupName in file.getGroupNames() ?? [] {
                    print("📁 Found group: \(groupName)")
                    if let group = file.openGroup(groupName) {
                        for datasetName in group.objectNames() {
                            print("📦 Found dataset: \(datasetName)")
                            if let dataset = group.openDataset(datasetName) {
                                let dims = dataset.space.dims
                                print("📐 Dataset '\(datasetName)' has dimensionality: \(dims)")
                                if dims.count == 3 {
                                    do {
                                        let dataspace = dataset.space
                                        let dims = dataspace.dims
                                        print("✅ Using dataset '\(datasetName)' with dims: \(dims)")

                                        let elementCount = dims.reduce(1, *)
                                        print("🔢 Total elements: \(elementCount)")
                                        
                                        var buffer = [Float](repeating: 0, count: Int(elementCount))
                                        
                                        
                                        try dataset.read(into: &buffer, type: NativeType.float)
                                        
                                        let width = dims[0]
                                        let height = dims[1]
                                        let channels = dims[2]
                                        
                                        var rawPixels = [Float]()

                                        // Use Accelerate for vectorized summing across channels
                                        print("🧮 Processing image data...")

                                        buffer.withUnsafeBufferPointer { bufPtr in
                                            let input = bufPtr.baseAddress!
                                            
                                            for i in 0..<width {
                                                for j in 0..<height {
                                                    let start = (i * height * channels) + (j * channels)
                                                    var sumSq: Float = 0
                                                    vDSP_svesq(input.advanced(by: start), 1, &sumSq, vDSP_Length(channels))
                                                    
                                                    // Calculate square root of sum of squares for each pixel
                                                    rawPixels.append(sqrt(sumSq))
                                                }
                                            }
                                        }

                                        // Normalize using max value and convert to UInt8 for image
                                        let maxVal = rawPixels.max() ?? 1
                                        var imagePixels = rawPixels.map { UInt8(min(255, ($0 / maxVal) * 255)) }

                                        print("🖼️ Attempting to create CGImage...")
                                        let colorSpace = CGColorSpaceCreateDeviceGray()
                                        let bitsPerComponent = 8
                                        let bytesPerRow = width
                                        let dataProvider = CGDataProvider(data: NSData(bytes: &imagePixels, length: imagePixels.count))

                                        if let cgImage = CGImage(
                                            width: width,
                                            height: height,
                                            bitsPerComponent: bitsPerComponent,
                                            bitsPerPixel: bitsPerComponent,
                                            bytesPerRow: bytesPerRow,
                                            space: colorSpace,
                                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                            provider: dataProvider!,
                                            decode: nil,
                                            shouldInterpolate: false,
                                            intent: .defaultIntent
                                        ) {
                                            let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: 256, height: 256))
                                            if let tiffData = nsImage.tiffRepresentation,
                                               let bitmapRep = NSBitmapImageRep(data: tiffData),
                                               let iconData = bitmapRep.representation(using: .png, properties: [:]) {
                                                print("✅ Successfully generated image thumbnail")
                                                return iconData.base64EncodedString()
                                            } else {
                                                print("⚠️ Failed to create bitmap representation")
                                            }
                                        } else {
                                            print("❌ Failed to create CGImage")
                                        }
                                    } catch {
                                        print("💥 Error processing dataset '\(datasetName)': \(error)")
                                    }
                                }
                            }
                        }
                    }
                }
            } else {
                print("❌ Failed to open HDF5 file.")
            }

            print("📎 Falling back to default icon.")
            let icon = NSWorkspace.shared.icon(forFile: fileURL.path)
            icon.size = NSSize(width: 256, height: 256)
            guard let cgImage = icon.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                print("❌ Failed to get default icon CGImage")
                return ""
            }
            let bitmapRep = NSBitmapImageRep(cgImage: cgImage)
            guard let iconData = bitmapRep.representation(using: .png, properties: [:]) else {
                print("❌ Failed to encode default icon image")
                return ""
            }
            return iconData.base64EncodedString()
        }()
        
        let iconHTML = "<img src='data:image/png;base64,\(iconBase64)' width='256' height='256' />"

        let html = """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="utf-8" />
            <style>
                html, body {
                    margin: 0;
                    padding: 0;
                    background-color: transparent;
                    font-family: -apple-system, system-ui, sans-serif;
                    font-size: 13px;
                    color: black;
                    height: 100%;
                }
                .container {
                    display: flex;
                    flex-direction: row;
                    height: 100%;
                    box-sizing: border-box;
                    padding: 16px;
                }
                .icon {
                    flex: 0 0 256px;
                    display: flex;
                    align-items: center;
                    justify-content: center;
                }
                .content {
                    flex: 1;
                    padding-left: 24px;
                    display: flex;
                    flex-direction: column;
                    justify-content: flex-start;
                }
                .header {
                    margin-bottom: 16px;
                }
                .header b {
                    font-size: 16px;
                    display: block;
                    margin-bottom: 4px;
                }
                .metadata {
                    white-space: pre-wrap;
                    overflow-y: auto;
                    color: #333;
                }
            </style>
        </head>
        <body>
            <div class="container">
                <div class="icon">\(iconHTML)</div>
                <div class="content">
                    <div class="header">
                        <b>\(fileName)</b>
                        Created: \(createdStr)<br/>
                        Modified: \(modifiedStr)<br/>
                        Size: \(readableSize)
                    </div>
                    <div class="metadata">\(metadata)</div>
                </div>
            </div>
        </body>
        </html>
        """

        return QLPreviewReply(dataOfContentType: .html, contentSize: CGSize(width: 700, height: 400)) { _ in
            return html.data(using: .utf8)!
        }
    }
    
    private func extractHDF5Metadata(from fileURL: URL) -> String? {
        guard let file = File.open(fileURL.path, mode: .readOnly) else {
            return nil
        }
        
        var metadata = ""
        let groups = file.getGroupNames() ?? ["<no groups>"]
        for groupName in groups {
            metadata += "📁 Group: \(groupName)\n"
            if let group = file.openGroup(groupName) {
                metadata += "  Datasets:\n"
                for dataset in group.objectNames() {
                    metadata += "    • \(dataset)\n"
                }

                metadata += "  Attributes:\n"
                for attributeName in group.attributeNames() {
                    if let attribute = group.openDoubleAttribute(attributeName) {
                        do {
                            let value = try attribute.read()
                            metadata += "    - \(attributeName): \(value)\n"
                        } catch {
                            if let attribute = group.openStringAttribute(attributeName) {
                                do {
                                    let value = try attribute.read()
                                    metadata += "    - \(attributeName): \(value)\n"
                                } catch {
                                    metadata += "    - \(attributeName): <error reading>\n"
                                }
                            }
                        }
                    }
                }
            } else {
                metadata += "  ⚠️ Failed to open group.\n"
            }
            metadata += "\n"
        }
        
        return metadata
    }
}
