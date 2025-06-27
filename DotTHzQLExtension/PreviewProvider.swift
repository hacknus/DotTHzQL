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

        let (iconBase64, previewSize): (String, NSSize) = {
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
                                        
                                        // Get dimensions (assuming standard [height, width, channels] format)
                                        let height = dims[0]
                                        let width = dims[1]
                                        let channels = dims[2]
                                        
                                        print("📏 Image dimensions: \(width) x \(height) with \(channels) channels")
                                        
                                        // Create an array to hold the processed pixel values
                                        var processedPixels = [Float](repeating: 0, count: Int(width * height))
                                        
                                        // Process the buffer data
                                        for y in 0..<height {
                                            for x in 0..<width {
                                                // Calculate position in the buffer
                                                let bufferIndex = (y * width + x) * channels
                                                
                                                // Calculate magnitude across all channels
                                                var sumSquares: Float = 0
                                                for c in 0..<channels {
                                                    let value = buffer[Int(bufferIndex) + Int(c)]
                                                    sumSquares += value * value
                                                }
                                                
                                                // Store the magnitude
                                                let pixelIndex = y * width + x
                                                processedPixels[Int(pixelIndex)] = sqrt(sumSquares)
                                            }
                                        }
                                        
                                        // Normalize the pixel values
                                        let maxValue = processedPixels.max() ?? 1.0
                                        let normalizedPixels = processedPixels.map { min(1.0, $0 / maxValue) }
                                        
                                        // Convert to UInt8 (0-255)
                                        var imageData = [UInt8](repeating: 0, count: Int(width * height))
                                        for i in 0..<normalizedPixels.count {
                                            imageData[i] = UInt8(normalizedPixels[i] * 255.0)
                                        }
                                        
                                        // Create the CGImage with the proper alignment
                                        let bitsPerComponent = 8
                                        let bitsPerPixel = 8
                                        
                                        // Ensure bytesPerRow is correctly aligned (must be a multiple of 4 for Core Graphics)
                                        let bytesPerRow = ((Int(width) * bitsPerPixel + 31) / 32) * 4
                                        
                                        // Create a properly aligned data buffer if needed
                                        var alignedData: [UInt8]
                                        if bytesPerRow == width {
                                            alignedData = imageData
                                        } else {
                                            alignedData = [UInt8](repeating: 0, count: Int(height) * bytesPerRow)
                                            for y in 0..<height {
                                                for x in 0..<width {
                                                    let srcIdx = Int(y * width + x)
                                                    let dstIdx = Int(y) * bytesPerRow + Int(x)
                                                    alignedData[dstIdx] = imageData[srcIdx]
                                                }
                                            }
                                        }
                                        
                                        let colorSpace = CGColorSpaceCreateDeviceGray()
                                        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue)
                                        
                                        guard let provider = CGDataProvider(data: Data(alignedData) as CFData) else {
                                            print("❌ Failed to create data provider")
                                            continue
                                        }
                                        
                                        guard let cgImage = CGImage(
                                            width: Int(width),
                                            height: Int(height),
                                            bitsPerComponent: bitsPerComponent,
                                            bitsPerPixel: bitsPerPixel,
                                            bytesPerRow: bytesPerRow,
                                            space: colorSpace,
                                            bitmapInfo: bitmapInfo,
                                            provider: provider,
                                            decode: nil,
                                            shouldInterpolate: false,
                                            intent: .defaultIntent
                                        ) else {
                                            print("❌ Failed to create CGImage")
                                            continue
                                        }
                                        
                                        // Create the properly sized preview image
                                        let previewWidth: CGFloat = 256.0
                                        let aspectRatio = CGFloat(height) / CGFloat(width)
                                        let previewHeight = round(previewWidth * aspectRatio)
                                        let previewSize = NSSize(width: previewWidth, height: previewHeight)
                                        
                                        let nsImage = NSImage(cgImage: cgImage, size: previewSize)
                                        
                                        if let tiffData = nsImage.tiffRepresentation,
                                           let bitmapRep = NSBitmapImageRep(data: tiffData),
                                           let pngData = bitmapRep.representation(using: .png, properties: [:]) {
                                            print("✅ Successfully generated image thumbnail")
                                            return (pngData.base64EncodedString(), previewSize)
                                        } else {
                                            print("⚠️ Failed to create PNG representation")
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
            let defaultSize = NSSize(width: 256, height: 256)
            let icon = NSWorkspace.shared.icon(forFile: fileURL.path)
            icon.size = defaultSize
            guard let cgImage = icon.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                print("❌ Failed to get default icon CGImage")
                return ("", defaultSize)
            }
            let bitmapRep = NSBitmapImageRep(cgImage: cgImage)
            guard let iconData = bitmapRep.representation(using: .png, properties: [:]) else {
                print("❌ Failed to encode default icon image")
                return ("", defaultSize)
            }
            return (iconData.base64EncodedString(), defaultSize)
        }()
        
        let iconHTML = "<img src='data:image/png;base64,\(iconBase64)' width='\(Int(previewSize.width))' height='\(Int(previewSize.height))' />"

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
                .icon img {
                    max-width: 100%;
                    max-height: 100%;
                    object-fit: contain;
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
            metadata += "\(groupName):\n"
            guard let group = file.openGroup(groupName) else {
                metadata += "  ⚠️ Failed to open group.\n\n"
                continue
            }

            let dsDescriptions: [String] = {
                if let attr = group.openStringAttribute("dsDescription"),
                   let rawList = try? attr.read(), let joined = rawList.first {
                    return joined.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                }
                return []
            }()

            let mdDescriptions: [String] = {
                if let attr = group.openStringAttribute("mdDescription"),
                   let rawList = try? attr.read(), let joined = rawList.first {
                    return joined.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                }
                return []
            }()

            // --- Datasets with descriptions by index ---
            let datasets = group.objectNames()
            metadata += "  Datasets:\n"
            for datasetName in datasets {
                var shapeDesc = ""
                if let dataset = group.openDataset(datasetName) {
                    let dims = dataset.space.dims.map { String($0) }.joined(separator: " x ")
                    shapeDesc = "(\(dims))"
                }
                var label = datasetName
                if datasetName.starts(with: "ds") {
                    let suffix = datasetName.dropFirst(2) // drops "ds"
                    if var index = Int(suffix) {
                        index -= 1
                        label = index < dsDescriptions.count ? dsDescriptions[index] : datasetName
                    }
                }
                metadata += "    • \(label): \(shapeDesc)\n"
            }

            // --- Metadata with descriptions by index ---
            let attributeNames = group.attributeNames()
                .filter { !["dsDescription", "mdDescription"].contains($0) }

            if !attributeNames.isEmpty {
                metadata += "  MetaData:\n"
                for attrName in attributeNames {
                    var label = attrName
                    var valueStr = "<unreadable>"
                    
                    if attrName.starts(with: "md") {
                        let suffix = attrName.dropFirst(2) // drops "md"
                        if var index = Int(suffix) {
                            index -= 1
                            label = index < mdDescriptions.count ? mdDescriptions[index] : attrName
                        }
                    }

                    if let attr = group.openDoubleAttribute(attrName), let val = try? attr.read() {
                        valueStr = "\(val)".replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: "")
                    } else if let attr = group.openStringAttribute(attrName), let val = try? attr.read() {
                        valueStr = "\(val)".replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: "")
                    }

                    metadata += "    - \(label): \(valueStr)\n"
                }
            }

            metadata += "\n"
        }

        return metadata
    }
}
