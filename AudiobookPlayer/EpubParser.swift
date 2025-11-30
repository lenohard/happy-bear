import Foundation
import ZIPFoundation

struct EpubChapter {
    let title: String
    let content: String
    let filename: String
}

enum EpubParserError: Error {
    case invalidArchive
    case containerMissing
    case rootfileMissing
    case contentMissing
    case parsingFailed
}

final class EpubParser: NSObject, XMLParserDelegate {
    private var currentElement = ""
    private var currentAttributes: [String: String] = [:]
    private var foundRootfile = ""
    
    // OPF Parsing
    struct ManifestItem {
        let href: String
        let properties: String?
        let mediaType: String?
    }
    private var manifest: [String: ManifestItem] = [:] // id -> ManifestItem
    private var spine: [String] = [] // idref
    private var metadataTitle = ""
    private var metadataCreator = ""
    
    // ToC Parsing
    private var tocMap: [String: String] = [:] // href (normalized) -> title
    private var currentNavLabel = ""
    private var currentNavHref = ""
    private var isParsingNavLabel = false // Inside <navLabel> (NCX)
    private var isParsingNavText = false  // Inside <text> (NCX)
    private var isParsingNavAnchor = false // Inside <a> (EPUB 3)
    
    func parse(epubURL: URL) throws -> (title: String, author: String?, chapters: [EpubChapter]) {
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempDir) }
        
        guard let archive = Archive(url: epubURL, accessMode: .read) else {
            throw EpubParserError.invalidArchive
        }
        
        for entry in archive {
            let destination = tempDir.appendingPathComponent(entry.path)
            try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            _ = try archive.extract(entry, to: destination)
        }
        
        // 1. Find OPF file from META-INF/container.xml
        let containerURL = tempDir.appendingPathComponent("META-INF/container.xml")
        guard let containerParser = XMLParser(contentsOf: containerURL) else {
            throw EpubParserError.containerMissing
        }
        containerParser.delegate = self
        foundRootfile = ""
        containerParser.parse()
        
        guard !foundRootfile.isEmpty else {
            throw EpubParserError.rootfileMissing
        }
        
        // 2. Parse OPF file
        let opfURL = tempDir.appendingPathComponent(foundRootfile)
        let opfBaseURL = opfURL.deletingLastPathComponent()
        guard let opfParser = XMLParser(contentsOf: opfURL) else {
            throw EpubParserError.parsingFailed
        }
        
        // Reset state for OPF parsing
        manifest = [:]
        spine = []
        metadataTitle = ""
        metadataCreator = ""
        
        opfParser.delegate = self
        opfParser.parse()
        
        // 3. Find and Parse ToC
        // Priority 1: EPUB 3 Navigation Document (properties="nav")
        // Priority 2: EPUB 2 NCX (media-type="application/x-dtbncx+xml" or id="ncx")
        
        var tocFile: String?
        
        // Look for Nav (EPUB 3)
        if let navItem = manifest.values.first(where: { $0.properties?.contains("nav") == true }) {
            tocFile = navItem.href
        } 
        // Look for NCX (EPUB 2)
        else if let ncxItem = manifest.values.first(where: { $0.mediaType == "application/x-dtbncx+xml" }) {
            tocFile = ncxItem.href
        }
        // Fallback: look for id="ncx"
        else if let ncxItem = manifest["ncx"] {
            tocFile = ncxItem.href
        }
        
        if let tocFile = tocFile {
            let tocURL = opfBaseURL.appendingPathComponent(tocFile)
            if let tocParser = XMLParser(contentsOf: tocURL) {
                tocMap = [:]
                tocParser.delegate = self
                tocParser.parse()
            }
        }
        
        // 4. Extract chapters
        var chapters: [EpubChapter] = []
        
        for (index, idref) in spine.enumerated() {
            guard let item = manifest[idref] else { continue }
            let href = item.href
            let chapterURL = opfBaseURL.appendingPathComponent(href)
            
            // Simple text extraction (stripping HTML tags)
            if let contentData = try? Data(contentsOf: chapterURL),
               let contentString = String(data: contentData, encoding: .utf8) {
                let stripped = contentString.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression, range: nil)
                    .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                
                if !stripped.isEmpty {
                    // Try to find title in ToC map
                    var title = "Chapter \(index + 1)"
                    
                    // 1. Try exact href match
                    if let tocTitle = tocMap[href] {
                        title = tocTitle
                    } 
                    // 2. Try filename match (ignoring path)
                    else {
                        let filename = URL(fileURLWithPath: href).lastPathComponent
                        if let tocTitle = tocMap[filename] {
                             title = tocTitle
                        }
                    }
                    
                    chapters.append(EpubChapter(
                        title: title,
                        content: stripped,
                        filename: href
                    ))
                }
            }
        }
        
        return (metadataTitle.isEmpty ? "Unknown Title" : metadataTitle.trimmingCharacters(in: .whitespacesAndNewlines),
                metadataCreator.isEmpty ? nil : metadataCreator.trimmingCharacters(in: .whitespacesAndNewlines),
                chapters)
    }
    
    // MARK: - XMLParserDelegate
    
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
        currentElement = elementName
        currentAttributes = attributeDict
        
        // Container
        if elementName == "rootfile", let fullPath = attributeDict["full-path"] {
            foundRootfile = fullPath
        }
        
        // OPF
        if elementName == "item", let id = attributeDict["id"], let href = attributeDict["href"] {
            let properties = attributeDict["properties"]
            let mediaType = attributeDict["media-type"]
            manifest[id] = ManifestItem(href: href, properties: properties, mediaType: mediaType)
        }
        
        if elementName == "itemref", let idref = attributeDict["idref"] {
            spine.append(idref)
        }
        
        // NCX (EPUB 2)
        if elementName == "navLabel" {
            isParsingNavLabel = true
        }
        if elementName == "text" && isParsingNavLabel {
            isParsingNavText = true
            currentNavLabel = ""
        }
        if elementName == "content", let src = attributeDict["src"] {
            // NCX content src usually has fragment (foo.html#bar)
            let srcPath = src.components(separatedBy: "#").first ?? src
            let trimmedLabel = currentNavLabel.trimmingCharacters(in: .whitespacesAndNewlines)
            
            if !trimmedLabel.isEmpty {
                // Store by full relative path
                if tocMap[srcPath] == nil {
                    tocMap[srcPath] = trimmedLabel
                }
                // Store by filename
                let filename = URL(fileURLWithPath: srcPath).lastPathComponent
                if tocMap[filename] == nil {
                    tocMap[filename] = trimmedLabel
                }
            }
        }
        
        // EPUB 3 Nav
        if elementName == "a", let href = attributeDict["href"] {
            currentNavHref = href
            isParsingNavAnchor = true
            currentNavLabel = ""
        }
    }
    
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if currentElement == "dc:title" {
            metadataTitle += string
        } else if currentElement == "dc:creator" {
            metadataCreator += string
        }
        
        if isParsingNavText || isParsingNavAnchor {
            currentNavLabel += string
        }
    }
    
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "navLabel" {
            isParsingNavLabel = false
        }
        if elementName == "text" {
            isParsingNavText = false
        }
        if elementName == "a" {
            // EPUB 3 Nav
            if isParsingNavAnchor {
                let trimmedLabel = currentNavLabel.trimmingCharacters(in: .whitespacesAndNewlines)
                if !currentNavHref.isEmpty && !trimmedLabel.isEmpty {
                     let srcPath = currentNavHref.components(separatedBy: "#").first ?? currentNavHref
                     
                     if tocMap[srcPath] == nil {
                         tocMap[srcPath] = trimmedLabel
                     }
                     let filename = URL(fileURLWithPath: srcPath).lastPathComponent
                     if tocMap[filename] == nil {
                         tocMap[filename] = trimmedLabel
                     }
                }
            }
            isParsingNavAnchor = false
            currentNavHref = ""
        }
    }
}
