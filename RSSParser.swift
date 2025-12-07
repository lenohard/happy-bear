import Foundation

// MARK: - RSS Feed Models

struct RSSFeed {
    let title: String
    let description: String?
    let imageURL: URL?
    let items: [RSSItem]
}

struct RSSItem {
    let title: String
    let description: String?
    let enclosureURL: URL?
    let enclosureLength: Int64
    let pubDate: Date?
    let guid: String?
}

// MARK: - RSS Parser

enum RSSParserError: LocalizedError {
    case invalidURL
    case networkError(Error)
    case parsingError(String)
    case noEnclosureFound
    
    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return NSLocalizedString("rss_error_invalid_url", value: "Invalid RSS feed URL", comment: "Invalid RSS feed URL")
        case .networkError(let error):
            let format = NSLocalizedString("rss_error_network", value: "Network error: %@", comment: "RSS network error format")
            return String(format: format, error.localizedDescription)
        case .parsingError(let message):
            let format = NSLocalizedString("rss_error_parsing", value: "Failed to parse RSS feed: %@", comment: "RSS parsing error format")
            return String(format: format, message)
        case .noEnclosureFound:
            return NSLocalizedString("rss_error_no_enclosure", value: "No audio enclosures found in RSS feed", comment: "No playable enclosures found")
        }
    }
}

final class RSSParser: NSObject {
    private var feed: RSSFeed?
    private var currentElement = ""
    private var currentTitle = ""
    private var currentDescription = ""
    private var currentEnclosureURL: URL?
    private var currentEnclosureLength: Int64 = 0
    private var currentPubDate: Date?
    private var currentGuid = ""
    
    private var feedTitle = ""
    private var feedDescription = ""
    private var feedImageURL: URL?
    private var items: [RSSItem] = []
    
    private var isInItem = false
    private var isInImage = false
    private var currentImageURLString = ""
    
    private var parsingError: Error?
    
    private static let dateFormatters: [DateFormatter] = {
        let rfc822 = DateFormatter()
        rfc822.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        rfc822.locale = Locale(identifier: "en_US_POSIX")
        
        let iso8601 = DateFormatter()
        iso8601.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        iso8601.locale = Locale(identifier: "en_US_POSIX")
        
        return [rfc822, iso8601]
    }()
    
    func parse(url: URL) async throws -> RSSFeed {
        // Fetch RSS feed data
        let (data, _) = try await URLSession.shared.data(from: url)
        
        // Parse XML
        let parser = XMLParser(data: data)
        parser.delegate = self
        
        // Reset state
        feed = nil
        items = []
        feedTitle = ""
        feedDescription = ""
        feedImageURL = nil
        isInItem = false
        isInImage = false
        parsingError = nil
        
        // Parse synchronously on background thread
        let success = parser.parse()
        
        if let error = parsingError {
            throw error
        }
        
        guard success else {
            if let error = parser.parserError {
                throw RSSParserError.parsingError(error.localizedDescription)
            }
            throw RSSParserError.parsingError("Unknown parsing error")
        }
        
        guard !items.isEmpty else {
            throw RSSParserError.noEnclosureFound
        }
        
        return RSSFeed(
            title: feedTitle.isEmpty ? "Untitled Feed" : feedTitle,
            description: feedDescription.isEmpty ? nil : feedDescription,
            imageURL: feedImageURL,
            items: items
        )
    }
}

// MARK: - XMLParserDelegate

extension RSSParser: XMLParserDelegate {
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
        currentElement = elementName
        
        switch elementName {
        case "item":
            isInItem = true
            currentTitle = ""
            currentDescription = ""
            currentEnclosureURL = nil
            currentEnclosureLength = 0
            currentPubDate = nil
            currentGuid = ""
            
        case "enclosure":
            if isInItem,
               let urlString = attributeDict["url"],
               let url = URL(string: urlString) {
                // Check if it's an audio file
                let ext = (url.pathExtension.lowercased())
                if PlayableMediaFormat.isPlayableExtension(ext) {
                    currentEnclosureURL = url
                    if let lengthString = attributeDict["length"],
                       let length = Int64(lengthString) {
                        currentEnclosureLength = length
                    }
                }
            }
            
        case "image":
            if !isInItem {
                isInImage = true
                currentImageURLString = ""
            }
            
        case "itunes:image":
            if !isInItem, feedImageURL == nil,
               let href = attributeDict["href"],
               let url = URL(string: href) {
                feedImageURL = url
            }
            
        default:
            break
        }
    }
    
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        
        switch currentElement {
        case "title":
            if isInItem {
                currentTitle += trimmed
            } else if !isInImage {
                feedTitle += trimmed
            }
            
        case "description":
            if isInItem {
                currentDescription += trimmed
            } else if !isInImage {
                feedDescription += trimmed
            }
            
        case "pubDate":
            if isInItem {
                for formatter in Self.dateFormatters {
                    if let date = formatter.date(from: trimmed) {
                        currentPubDate = date
                        break
                    }
                }
            }
            
        case "guid":
            if isInItem {
                currentGuid += trimmed
            }
            
        case "url":
            if isInImage {
                currentImageURLString += trimmed
            }
            
        default:
            break
        }
    }
    
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "item" {
            // Only add items that have audio enclosures
            if let enclosureURL = currentEnclosureURL {
                let item = RSSItem(
                    title: currentTitle.isEmpty ? "Untitled Episode" : currentTitle,
                    description: currentDescription.isEmpty ? nil : currentDescription,
                    enclosureURL: enclosureURL,
                    enclosureLength: currentEnclosureLength,
                    pubDate: currentPubDate,
                    guid: currentGuid.isEmpty ? nil : currentGuid
                )
                items.append(item)
            }
            
            isInItem = false
        } else if elementName == "image" {
            if isInImage {
                if let url = URL(string: currentImageURLString) {
                    feedImageURL = url
                }
                isInImage = false
            }
        }
        
        currentElement = ""
    }
    
    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        parsingError = RSSParserError.parsingError(parseError.localizedDescription)
    }
}