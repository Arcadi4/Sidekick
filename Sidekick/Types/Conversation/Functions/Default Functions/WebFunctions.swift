//
//  WebFunctions.swift
//  Sidekick
//
//  Created by John Bean on 4/15/25.
//

import AppKit
import ExtractKit_macOS
import Foundation

public class WebFunctions {
    
    static var functions: [AnyFunctionBox] {
        var functions: [AnyFunctionBox] = [
            WebFunctions.getWebsiteContent,
            WebFunctions.draftEmail,
            WebFunctions.getLocation
        ]
        // Add web search function
        let provider: RetrievalSettings.SearchProvider = RetrievalSettings.SearchProvider(
            rawValue: RetrievalSettings.defaultSearchProvider
        ) ?? .duckDuckGo
        if provider == .tavily {
            functions.append(WebFunctions.tavilyWebSearch)
        } else {
            functions.append(WebFunctions.duckDuckGoWebSearch)
        }
        return functions
    }
    
    /// Custom error for Web Search functions
    enum WebSearchError: LocalizedError {
        case notConfigured
        case invalidDateFormat
        var errorDescription: String? {
            switch self {
                case .invalidDateFormat:
                    return "Invalid date format"
                case .notConfigured:
                    return "Web search has not been properly configured in Settings."
            }
        }
    }
    
    /// A function to convert strings to dates
    private static func convertStringToDate(
        _ input: String
    ) throws -> Date {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        // Check if date can be extracted
        if let date = dateFormatter.date(from: input) {
            return date
        } else {
            throw WebSearchError.invalidDateFormat
        }
    }
    
    /// A function to check if a web function was used
    public static func includesWebFunction(
        functionNames: [String]
    ) -> Bool {
        return WebFunctions.functions.contains { function in
            functionNames.contains(function.name)
        }
    }
    
    /// A ``Function`` to conduct a web search with Tavily
    static let tavilyWebSearch = Function<TavilyWebSearchParams, String>(
        name: "web_search",
        description: "Retrieves information from the web with the provided query, instead of estimating it.",
        params: [
            FunctionParameter(
                label: "query",
                description: "The topic to look up online",
                datatype: .string,
                isRequired: true
            ),
            FunctionParameter(
                label: "site",
                description: "Search within this specific site (optional, example: wikipedia.org, default: nil)",
                datatype: .string,
                isRequired: false
            ),
            FunctionParameter(
                label: "num_results",
                description: "The maximum number of search results (optional, default: 10)",
                datatype: .integer,
                isRequired: false
            ),
            FunctionParameter(
                label: "time_range",
                description: "The time range back from the current date to filter results. (optional, options: day, week, month, year, default: nil)",
                datatype: .string,
                isRequired: false
            )
        ],
        run: { params in
            // Check if enabled
            if !RetrievalSettings.canUseWebSearch {
                throw WebSearchError.notConfigured
            }
            // Conduct search
            let sources: [Source] = try await TavilySearch.search(
                query: params.query,
                site: params.site,
                resultCount: params.num_results ?? 10,
                timeRange: params.time_range
            )
            // Convert to JSON
            let sourcesInfo: [Source.SourceInfo] = sources.map(
                \.info
            )
            let jsonEncoder: JSONEncoder = JSONEncoder()
            jsonEncoder.outputFormatting = [.prettyPrinted]
            let jsonData: Data = try! jsonEncoder.encode(sourcesInfo)
            let resultsText: String = String(
                data: jsonData,
                encoding: .utf8
            )!
            return """
Below are the sites and corresponding content returned from your `web_search` query.

The content from each site here is an incomplete except. Use the `get_website_content` function to get the full content from a website.

\(resultsText)
"""
        }
    )
    struct TavilyWebSearchParams: FunctionParams {
        let query: String
        let site: String?
        let num_results: Int?
        let time_range: TavilySearch.TimeRange?
    }
    
    /// A ``Function`` to conduct a web search with DuckDuckGo
    static let duckDuckGoWebSearch = Function<DuckDuckGoSearchParams, String>(
        name: "web_search",
        description: "Retrieves information from the web with the provided query, instead of estimating it.",
        params: [
            FunctionParameter(
                label: "query",
                description: "The topic to look up online",
                datatype: .string,
                isRequired: true
            ),
            FunctionParameter(
                label: "site",
                description: "Search within this specific site (optional, example: wikipedia.org, default: nil)",
                datatype: .string,
                isRequired: false
            ),
            FunctionParameter(
                label: "num_results",
                description: "The maximum number of search results (optional, default: 3, maximum: 5)",
                datatype: .integer,
                isRequired: false
            ),
            FunctionParameter(
                label: "start_date",
                description: "The start date of search results, in the format `yyyy-MM-dd`. (optional)",
                datatype: .string,
                isRequired: false
            ),
            FunctionParameter(
                label: "end_date",
                description: "The end date of search results, in the format `yyyy-MM-dd`. (optional)",
                datatype: .string,
                isRequired: false
            ),
        ],
        run: { params in
            // Check if enabled
            if !RetrievalSettings.canUseWebSearch {
                throw WebSearchError.notConfigured
            }
            // Get start and end date
            let startDate: Date? = try {
                if let start_date = params.start_date {
                    return try WebFunctions.convertStringToDate(
                        start_date
                    )
                }
                return nil
            }()
            let endDate: Date? = try {
                if let end_date = params.end_date {
                    return try WebFunctions.convertStringToDate(
                        end_date
                    )
                }
                return nil
            }()
            // Conduct search
            let numResults: Int = params.num_results ?? 3
            let sources: [Source] = try await DuckDuckGoSearch.search(
                query: params.query,
                site: params.site,
                resultCount: 5,
                startDate: startDate,
                endDate: endDate
            )
            // Get full content
            var remainingTokens: Int = 80_000 // Max 80K tokens
            var sourceContents: [Source.SourceContent] = await sources.concurrentMap { source in
                // Trim to fit max input tokens
                let result = try? await source.getContent()
                return result
            }.compactMap {
                $0
            }
            // Sort and drop
            sourceContents = sourceContents.dropLast(
                max(sourceContents.count - numResults, 0)
            ).sorted(
                by: \.content.estimatedTokenCount
            )
            // Trim
            sourceContents = sourceContents
                .enumerated()
                .map { (index, content) in
                    // Trim
                    var content: Source.SourceContent = content
                    let result = content.content.trimmingSuffixToTokens(
                        maxTokens: remainingTokens
                    )
                    // Mutate variables to track
                    content.content = result.trimmed
                    remainingTokens -= result.usedTokens
                    return content
                }
            let jsonEncoder: JSONEncoder = JSONEncoder()
            jsonEncoder.outputFormatting = [.prettyPrinted]
            let jsonData: Data = try! jsonEncoder.encode(
                sourceContents
            )
            let resultsText: String = String(
                data: jsonData,
                encoding: .utf8
            )!
            return """
Below are the sites and corresponding content returned from your `web_search` query.

\(resultsText)
"""
        }
    )
    struct DuckDuckGoSearchParams: FunctionParams {
        let query: String
        let site: String?
        let num_results: Int?
        let start_date: String?
        let end_date: String?
    }
    
    /// A function to get the content of a website via its url
    static let getWebsiteContent = Function<GetWebsiteContentParams, String>(
        name: "get_website_content",
        description: "Retrieves the full content of a website via its URL.",
        params: [
            FunctionParameter(
                label: "url",
                description: "The website's URL",
                datatype: .string,
                isRequired: true
            )
        ],
        run: { params in
            return try await WebFunctions.scrapeWebsite(
                url: params.url
            )
        }
    )
    struct GetWebsiteContentParams: FunctionParams {
        let url: String
    }
    
    /// Function to scrape the contents of a website
    static func scrapeWebsite(url: String) async throws -> String {
        // Check URL
        guard let url: URL = URL(string: url) else {
            throw GetWebsiteContentError.invalidUrl
        }
        // Extract text
        return try await ExtractKit.shared.extractText(
            url: url,
            contentType: .website
        )
        // Custom error for Web Search function
        enum GetWebsiteContentError: LocalizedError {
            case invalidUrl
            var errorDescription: String? {
                switch self {
                    case .invalidUrl:
                        return "The provided website URL is invalid."
                }
            }
        }
    }
    
    /// A function to create an email draft
    static let draftEmail = Function<DraftEmailParams, String>(
        name: "draft_email",
        description: "Uses the \"mailto:\" URL scheme to create an email draft in the default email client.",
        params: [
            FunctionParameter(
                label: "recipients",
                description: "An array containing the email addresses of the recipients.",
                datatype: .stringArray,
                isRequired: true
            ),
            FunctionParameter(
                label: "cc",
                description: "An array containing the email addresses of the cc recipients.",
                datatype: .stringArray,
                isRequired: true
            ),
            FunctionParameter(
                label: "bcc",
                description: "An array containing the email addresses of the cc recipients.",
                datatype: .stringArray,
                isRequired: true
            ),
            FunctionParameter(
                label: "subject",
                description: "The subject of the email",
                datatype: .string,
                isRequired: true
            ),
            FunctionParameter(
                label: "body",
                description: "The body of the email.",
                datatype: .string,
                isRequired: true
            )
        ],
        run: { params in
            // Formulate URL
            var urlString: String = "mailto:"
            urlString += params.recipients.joined(separator: ",")
            // Start query parameters
            var queryItems: [String] = []
            // Add CC & BCC recipients if present
            if let cc = params.cc, !cc.isEmpty {
                queryItems.append("cc=\(cc.joined(separator: ","))")
            }
            if let bcc = params.bcc, !bcc.isEmpty {
                queryItems.append("bcc=\(bcc.joined(separator: ","))")
            }
            // Add subject & body
            if !params.subject.isEmpty {
                queryItems.append("subject=\(params.subject)")
            }
            if !params.body.isEmpty {
                queryItems.append("body=\(params.body)")
            }
            // Append query parameters if there are any
            if !queryItems.isEmpty {
                urlString += "?" + queryItems.joined(separator: "&")
            }
            // URL encode the string
            guard let encodedString = urlString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
                throw DraftEmailError.percentEncodingFailed
            }
            // Formulate and open URL
            guard let url: URL = URL(string: encodedString) else {
                throw DraftEmailError.urlCreationFailed
            }
            let _ = NSWorkspace.shared.open(url)
            return "Successfully created email draft"
            enum DraftEmailError: LocalizedError {
                
                case percentEncodingFailed
                case urlCreationFailed
                
                var errorDescription: String? {
                    switch self {
                        case .percentEncodingFailed:
                            return "Failed to add percent encoding to `mailto` URL"
                        case .urlCreationFailed:
                            return "Failed to create URL from `mailto` string"
                    }
                }
            }
        }
    )
    struct DraftEmailParams: FunctionParams {
        let recipients: [String]
        let cc: [String]?
        let bcc: [String]?
        let subject: String
        let body: String
    }
    
    /// A function to get the user's location
    static let getLocation = Function<BlankParams, String>(
        name: "get_location",
        description: "A function to get the user's location. Use this before providing answers that depend on location, such as weather or holidays.",
        params: [
        ],
        run: { params in
            return try await IPLocation.getLocation()
        }
    )
    struct BlankParams: FunctionParams {}
    
}
