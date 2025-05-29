//
//  Message.swift
//  Sidekick
//
//  Created by Bean John on 10/4/24.
//

import Foundation
import SimilaritySearchKit
import SwiftUI

public struct Message: Identifiable, Codable, Hashable {
	
	init(
		text: String,
		sender: Sender,
		model: String? = nil,
        functionCallRecords: [FunctionCallRecord]? = nil,
		expertId: UUID? = nil
    ) {
        self.id = UUID()
        self.text = text
        self.sender = sender
        self.startTime = .now
        self.lastUpdated = .now
        self.outputEnded = false
        let modelName: String = model ?? String(
            localized: "Unknown"
        )
        self.model = modelName
        self.functionCallRecords = functionCallRecords
        self.expertId = expertId
    }
	
	init(
		imageUrl: URL,
		prompt: String,
		expertId: UUID? = nil
	) {
		self.id = UUID()
		self.text = "Generated an image with the prompt \"\(prompt)\"."
		self.sender = .system
		self.startTime = .now
		self.lastUpdated = .now
		self.outputEnded = true
		self.model = "Image Playground Model"
		self.imageUrl = imageUrl
		self.expertId = expertId
	}
	
	/// A `UUID` for `Identifiable` conformance
	public var id: UUID = UUID()
	
	/// A `ContentType` for the message
	public var contentType: Self.ContentType {
		if self.imageUrl != nil {
			return .image
		}
		return .text
	}
	
	/// Stored property for the message text
	public var text: String
	
	/// Computed property returning the response text
	public var responseText: String {
		return self.text.reasoningRemoved
	}
	
	/// A `String` containing the message's reasoning process
	public var reasoningText: String? {
		// Return nil if sender is not assistant
		if self.sender != .assistant { return nil }
		// List special reasoning tokens
        let specialTokenSets: [[String]] = String.specialReasoningTokens
		// Extract text between tokens
		// For each set of tokens
		for specialTokenSet in specialTokenSets {
			// Get range of start token
			if let startRange = self.text.range(
				of: specialTokenSet.first!
			) {
				// Get range of end token
				if let endRange = self.text.range(
					of: specialTokenSet.last!,
					range: startRange.upperBound..<text.endIndex
				) {
					// Return text
					return String(
						self.text[startRange.upperBound..<endRange.lowerBound]
					).trimmingCharacters(in: .whitespacesAndNewlines)
				} else if !self.outputEnded {
					// If still outputting, show unfinished reasoning text
					return String(
						self.text[startRange.upperBound..<text.endIndex]
					).trimmingCharacters(in: .whitespacesAndNewlines)
				}
			}
		}
		// If failed to locate reasoning text, return nil
		return nil
	}
	
	/// A `Bool` representing if the message is contains a reasoning process
	public var hasReasoning: Bool {
		// Return true if...
		// a.) There are reasoning tokens
        // b.) The reasoning process is not nil
		// c.) The message does come from a model
        guard let reasoningText = self.reasoningText else { return false }
        return (!reasoningText.isEmpty) && (self.sender == .assistant)
	}
	
	/// Function returning the message text that is submitted to the LLM
	public func textWithSources(
		similarityIndex: SimilarityIndex?,
		useWebSearch: Bool,
		temporaryResources: [TemporaryResource]
	) async -> (
		text: String,
		sources: Int
	) {
		// If assistant or system, no sources needed
		if self.sender != .user {
			return (self.text, 0)
		}
		// Search in expert resources
		// If no resources, return blank array
		let hasResources: Bool = similarityIndex != nil && !(similarityIndex?.indexItems.isEmpty ?? true)
		let searchResultsMultiplier: Int = RetrievalSettings.searchResultsMultiplier * 2
		let resourcesSearchResults: [SearchResult] = await similarityIndex?.search(
			query: text,
			maxResults: searchResultsMultiplier
		) ?? []
        let resourcesResults: [Source] = resourcesSearchResults.map { result in
            // If search result context is not being used, skip
            if !RetrievalSettings.useWebSearchResultContext {
                return Source(
                    text: result.text,
                    source: result.sourceUrlText!
                )
            }
            // Get item index and source url
            guard let index: Int = result.itemIndex,
                  let sourceUrl: String = result.sourceUrlText,
                  let similarityIndex: SimilarityIndex = similarityIndex else {
                return Source(
                    text: result.text,
                    source: result.sourceUrlText!
                )
            }
            // Get items in the same file
            return Source.appendSourceContext(
                index: index,
                text: result.text,
                sourceUrlText: sourceUrl,
                similarityIndex: similarityIndex
            )
        }
		// Search Tavily
		var resultCount: Int = (hasResources && !resourcesResults.isEmpty) ? 1 : 2
		resultCount = resultCount * searchResultsMultiplier
		var searchResults: [Source]? = []
		if useWebSearch {
            searchResults = try? await WebSearch.search(
                query: text,
                resultCount: resultCount
            )
		}
		// Get temporary resources as sources
		let temporaryResourcesSources: [Source] = temporaryResources.map(
			\.source
		).compactMap({ $0 })
		// Combine
		let results: [Source] = resourcesResults + (
            searchResults ?? []
		) + temporaryResourcesSources
		// Save sources
		let sources: Sources = Sources(
			messageId: self.id,
			sources: results
		)
		SourcesManager.shared.add(sources)
		// Skip if no results
		if results.isEmpty {
			return (self.text, 0)
		}
        // Convert to JSON
        let sourcesInfo: [Source.SourceInfo] = results.map(\.info)
        let jsonEncoder: JSONEncoder = JSONEncoder()
        jsonEncoder.outputFormatting = [.prettyPrinted]
        let jsonData: Data = try! jsonEncoder.encode(sourcesInfo)
        let resultsText: String = String(
            data: jsonData,
            encoding: .utf8
        )!
		let messageText: String = """
\(self.text)

Below is information that may or may not be relevant to my request in JSON format. 

When multiple sources provide correct, but conflicting information (e.g. different definitions), ALWAYS use sources from files, not websites. 

If your response uses information from one or more provided sources I provided, your response MUST be directly followed with a single exaustive LIST OF FILEPATHS AND URLS of ALL referenced sources, in the format [{"url": "/path/to/referenced/file.pdf"}, {"url": "/path/to/another/referenced/file.docx"}, {"url": "https://referencedwebsite.com"}, "https://anotherreferencedwebsite.com"}]

This list should be the only place where references and sources are addressed, and MUST not be preceded by a header or a divider.

If I did not provide sources, YOU MUST NOT end your response with a list of filepaths and URLs. If no sources were provided, DO NOT mention the lack of sources.

If you did not use the information I provided, YOU MUST NOT end your response with a list of filepaths and URLs. 

DO NOT reference sources outside of those provided below. If you did not reference provided sources, do not mention sources in your response.

\(resultsText)
"""
		return (messageText, results.count)
	}
	
	/// A `Double` representing the number of tokens outputted per second
	public var tokensPerSecond: Double?
	
	/// The model's name, of type `String`
	public let model: String
	
	/// The ``Sender`` of the message (`user`, `system` or `assistant`)
	private var sender: Sender
	
	/// The `UUID` of the expert used
	public var expertId: UUID?
	
	/// A `URL` for an image generated, if any
	public var imageUrl: URL?
	/// An `Image` loaded from the `imageUrl`, if any
	public var image: some View {
		Group {
			if let url = imageUrl {
				AsyncImage(
					url: url,
					content: { image in
						image
							.resizable()
							.aspectRatio(contentMode: .fit)
							.frame(
								maxWidth: 350,
								maxHeight: 350
							)
							.clipShape(
								UnevenRoundedRectangle(
									topLeadingRadius: 0,
									bottomLeadingRadius: 13,
									bottomTrailingRadius: 13,
									topTrailingRadius: 13
								)
							)
							.draggable(
								Image(
									nsImage: NSImage(
										contentsOf: url
									)!
								)
							)
							.onTapGesture(count: 2) {
								NSWorkspace.shared.open(url)
							}
							.contextMenu {
								Button {
									NSWorkspace.shared.open(url)
								} label: {
									Text("Open")
								}
							}
					},
					placeholder: {
						ProgressView()
							.padding(11)
					}
				)
			} else {
				EmptyView()
			}
		}
	}
    
    /// An array of ``FunctionCallRecord`` used in the response
    public var functionCallRecords: [FunctionCallRecord]? = nil
	/// A `Bool` representing whether the message did execute function calls
    public var hasFunctionCallRecords: Bool {
        guard let functionCallRecords else { return false }
        return !functionCallRecords.isEmpty
    }
    
	/// An array for `URL` of sources referenced in a response
	public var referencedURLs: [ReferencedURL] = []
	
	/// Function to get the sender
	public func getSender() -> Sender {
		return self.sender
	}
	
	/// A `View` for the sender's icon
	var icon: some View {
		Group {
			if let expertId = self.expertId,
			   let expert = ExpertManager.shared.getExpert(id: expertId)
			{
				expert.icon
			} else {
				sender.icon
			}
		}
	}
	
	/// Stored property for the start time of interaction
	public var startTime: Date
	/// Stored property for the most recent update time
	public var lastUpdated: Date
	
	/// Stored property for the time taken for a response to start
	public var responseStartSeconds: Double?
	
	/// Stored property for whether the output has finished
	public var outputEnded: Bool
	
	/// A ``Snapshot`` of canvas content
	public var snapshot: Snapshot? = nil
	
	/// Function to update message
	@MainActor
	public mutating func update(
		response: LlamaServer.CompleteResponse,
		includeReferences: Bool
	) {
		// Set variables
		self.tokensPerSecond = response.predictedPerSecond
		self.responseStartSeconds = response.responseStartSeconds
		self.lastUpdated = .now
        // Decode text for extract text and references
        let text: String = response.text.dropSuffixIfPresent("[]")
		let delimiters: [String] = ["\n[", " ["]
		// Set text as default if reference extraction fails
		self.text = text
		// For each delimiter
		for delimiter in delimiters {
			let messageText: String = text.dropFollowingSubstring(
				delimiter,
				options: .backwards
			)
				.trimmingWhitespaceAndNewlines()
				.dropSuffixIfPresent(
					"Sources"
				).dropSuffixIfPresent(
					"References"
				)
				.dropSuffixIfPresent(
					"**Sources**"
				).dropSuffixIfPresent(
					"**References**"
				)
				.dropSuffixIfPresent(
					"Sources:"
				).dropSuffixIfPresent(
					"References:"
				).dropSuffixIfPresent(
					"**Sources:**"
				).dropSuffixIfPresent(
					"**References:**"
				).dropSuffixIfPresent(
					"**Sources**:"
				).dropSuffixIfPresent(
					"**References**:"
				).dropSuffixIfPresent(
					"List of Filepaths and URLs:"
				)
				.trimmingWhitespaceAndNewlines()
			let jsonText: String = text.dropPrecedingSubstring(
				delimiter,
				options: .backwards,
				includeCharacter: true
			)
			// Decode references if needed
			if includeReferences, let data: Data = try? jsonText.data() {
				// Decode data
				if let references = ReferencedURL.fromData(
					data: data
				) {
					self.referencedURLs = references
					self.text = messageText
				}
			}
		}
		// Try to extract snapshot
		self.updateSnapshot()
	}
	
	/// Function to extract snapshots if available
	private mutating func updateSnapshot() {
		// Try to extract site
		if let site = Snapshot.Site.extractSite(
			from: self.responseText
		) {
			self.snapshot = Snapshot(site: site)
			self.snapshot?.site?.saveToCache()
		}
	}
		
	
	/// Function to end a message
	public mutating func end() {
		self.lastUpdated = .now
		self.outputEnded = true
	}
	
    public struct MessageSubset: Codable {
        
        init(
            modelType: ModelType = .regular,
            usingRemoteModel: Bool,
            message: Message,
            similarityIndex: SimilarityIndex? = nil,
            temporaryResources: [TemporaryResource] = [],
            shouldAddSources: Bool = false,
            useReasoning: Bool = true,
            useVisionContent: Bool = false,
            useWebSearch: Bool = false,
            useCanvas: Bool = false,
            canvasSelection: String? = nil
        ) async {
            self.role = message.sender
            // Set up mutable message
            var message: Message = message
            // Apply changes for Canvas
            if useCanvas, let canvasSelection = canvasSelection, !canvasSelection.isEmpty {
                message.text = """
\(message.text)

I have selected the range "\(canvasSelection)". Output the full text again with the changes applied. Keep as much of the previous text as available. 
"""
            } else if useCanvas {
                message.text = """
\(message.text)

Output the full text again with the changes applied. Keep as much of the previous text as available.
"""
            }
            // Apply Canvas changes if needed
            if let snapshot = message.snapshot,
               snapshot.type == .text,
               let ogText: String = snapshot.originalText {
                message.text = message.text.replacingOccurrences(
                    of: ogText,
                    with: snapshot.text
                )
            }
            // Add sources if needed
            if shouldAddSources {
                // Initialize the content based on the useVisionContent flag.
                if useVisionContent {
                    var contentArr: [Content] = []
                    // Add text content, stripping images
                    let textContentStr: String = await message.textWithSources(
                        similarityIndex: similarityIndex,
                        useWebSearch: useWebSearch,
                        temporaryResources: temporaryResources.filter({ !$0.isImage })
                    ).text
                    let textContentItem: Content = .text(textContentStr)
                    contentArr.append(textContentItem)
                    // Add image content
                    let maxEdge: CGFloat = 900 / 2
                    let imageUrls: [URL] = temporaryResources.filter({ $0.isImage }).map(\.url)
                    let encodedImages: [String] = imageUrls.compactMap { url in
                        guard let image = NSImage(contentsOf: url) else {
                            return nil // Return nil if file can't be read as image
                        }
                        let originalSize = image.size
                        let maxOriginalEdge = max(originalSize.width, originalSize.height)
                        var resizedImage = image
                        // Only resize if one of the dimensions is larger than maxEdge
                        if maxOriginalEdge > maxEdge {
                            let scale = maxEdge / maxOriginalEdge
                            let newSize = NSSize(width: originalSize.width * scale, height: originalSize.height * scale)
                            let newImage = NSImage(size: newSize)
                            newImage.lockFocus()
                            // Set high interpolation quality to ensure sharp resized image
                            NSGraphicsContext.current?.imageInterpolation = .default
                            image.draw(
                                in: NSRect(origin: .zero, size: newSize),
                                from: NSRect(origin: .zero, size: originalSize),
                                operation: .copy,
                                fraction: 1.0
                            )
                            newImage.unlockFocus()
                            resizedImage = newImage
                        }
                        guard let tiffData = resizedImage.tiffRepresentation,
                              let bitmap = NSBitmapImageRep(data: tiffData),
                              let pngData = bitmap.representation(
                                using: .png,
                                properties: [.compressionFactor: 0.95]
                              ) else {
                            return nil // Return nil if image can't be encoded
                        }
                        let encoding: String = pngData.base64EncodedString()
                        return "data:image/png;base64,\(encoding)"
                    }
                    let imageContentItems: [Content] = encodedImages.map { encodedImage in
                        return .imageURL(ImageURL(url: encodedImage))
                    }
                    contentArr += imageContentItems
                    self.content = .multimodal(contentArr)
                } else {
                    // Else, initialize text content
                    let textContentStr: String = await message.textWithSources(
                        similarityIndex: similarityIndex,
                        useWebSearch: useWebSearch,
                        temporaryResources: temporaryResources
                    ).text
                    self.content = .textOnly(textContentStr)
                }
            } else {
                // Else, just use message text
                let plainText: String = message.text
                self.content = .textOnly(plainText)
            }
            // If message requires reasoning, and can be toggled
            let knownModel: KnownModel? = await {
                switch modelType {
                    case .regular:
                        return await Model.shared.selectedModel
                    case .worker:
                        return await Model.shared.selectedWorkerModel
                    case .completions:
                        return nil
                }
            }()
            if let selectedModel = knownModel,
               selectedModel.isHybridReasoningModel,
               let style: KnownModel.HybridReasoningStyle = selectedModel.hybridReasoningStyle {
                // Append reasoning toggle tag
                let toggleTag: String = style.getTag(
                    useReasoning: useReasoning
                )
                switch self.content {
                    case .textOnly(let string):
                        self.content = .textOnly(string + toggleTag)
                    case .multimodal(let array):
                        let newContents: [Content] = array.map { content in
                            switch content {
                                case .text(let string):
                                    return .text(string + toggleTag)
                                default:
                                    return content
                            }
                        }
                        self.content = .multimodal(newContents)
                }
            }
        }
        
        /// A ``Sender`` object representing the sender
        var role: Sender
        /// The message's content
        var content: ContentValue
        
        public enum Content: Codable {
            
            case text(String)
            case imageURL(ImageURL)
            
            private enum CodingKeys: String, CodingKey {
                case type
                case text
                case imageURL = "image_url"
            }
            
            public init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                let type = try container.decode(String.self, forKey: .type)
                
                switch type {
                    case "text":
                        let text = try container.decode(String.self, forKey: .text)
                        self = .text(text)
                    case "image_url":
                        let imageUrl = try container.decode(ImageURL.self, forKey: .imageURL)
                        self = .imageURL(imageUrl)
                    default:
                        throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Invalid content type")
                }
            }
            
            public func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                switch self {
                    case .text(let text):
                        try container.encode("text", forKey: .type)
                        try container.encode(text, forKey: .text)
                    case .imageURL(let url):
                        try container.encode("image_url", forKey: .type)
                        try container.encode(url, forKey: .imageURL)
                }
            }
        }
        
        public struct ImageURL: Codable {
            let url: String
        }
        
        public enum ContentValue: Codable {
            
            case textOnly(String)
            case multimodal([Content])
            
            public init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                // Try decoding as a String (single mode)
                if let stringValue = try? container.decode(String.self) {
                    self = .textOnly(stringValue)
                    return
                }
                // Then try decoding as a [Content] array (multimodal mode)
                if let arrayValue = try? container.decode([Content].self) {
                    self = .multimodal(arrayValue)
                    return
                }
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Unable to decode ContentValue as either a String or an array of Content"
                )
            }
            
            public func encode(to encoder: Encoder) throws {
                var container = encoder.singleValueContainer()
                switch self {
                    case .textOnly(let str):
                        try container.encode(str)
                    case .multimodal(let contents):
                        try container.encode(contents)
                }
            }
        }
           
    }
	
	public enum ContentType: String, CaseIterable {
		case text
		case image
	}
	
}
