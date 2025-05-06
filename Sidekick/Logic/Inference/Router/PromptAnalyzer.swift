//
//  PromptAnalyzer.swift
//  Sidekick
//
//  Created by John Bean on 12/19/24.
//

import CoreML
import Foundation
import ImagePlayground
import NaturalLanguage

public class PromptAnalyzer {
	
    /// Function to detect if reasoning is required by the prompt
    /// - Parameter prompt: The user's prompt
    /// - Returns: A `Bool` representing whether reasoning should be toggled on or off
    @MainActor
    public static func isReasoningRequired(
        _ prompt: String
    ) -> Bool? {
        // Check if model is a hybrid reasoning model
        guard let model = Model.shared.selectedModel,
                model.isHybridReasoningModel else {
            return nil
        }
        // Init classifier model
        let mlModelConfig = MLModelConfiguration()
        mlModelConfig.computeUnits = .all
        guard let promptClassifier: NLModel = try? NLModel(
            mlModel: MLModel(
                contentsOf: Bundle.main.url(
                    forResource: "ReasoningClassifier",
                    withExtension: "mlmodelc"
                )!
            )
        ) else {
            return nil
        }
        // Run classifier
        let hypotheses: [String: Double] = promptClassifier.predictedLabelHypotheses(
            for: prompt,
            maximumCount: ReasoningHypothesis.allCases.count
        )
        let reasoningScore: Double = hypotheses[ReasoningHypothesis.reasoning.rawValue] ?? 1.0
        let noReasoningScore: Double = hypotheses[ReasoningHypothesis.noReasoning.rawValue] ?? 1.0
        // Return result
        return reasoningScore > noReasoningScore
    }
    
    /// The expected result type of a prompt
    public enum ReasoningHypothesis: String, CaseIterable {
        
        init?(
            _ rawValue: String
        ) {
            if let hypothesis: ReasoningHypothesis = Self.allCases.filter({ type in
                type.rawValue == rawValue
            }).first {
                self = hypothesis
            } else {
                return nil
            }
        }
        
        case reasoning = "reasoning"
        case noReasoning = "no-reasoning"
        
    }
    
	/// Function to detect what results are expected by the prompt
	/// - Parameter prompt: The user's prompt
	/// - Returns: The format of the content to be generated
	@MainActor
	public static func getExpectedResultType(
		_ prompt: String
    ) -> ResultType {
        // Check what types are available
        let resultTypes: [ResultType] = ResultType.allCases.filter(\.isAvailable)
        // If only one type is available, return it
        if resultTypes.count == 1 {
            return resultTypes.first!
        }
        // Else, init classifier model
        let mlModelConfig = MLModelConfiguration()
        mlModelConfig.computeUnits = .all
        guard let promptClassifier: NLModel = try? NLModel(
            mlModel: MLModel(
                contentsOf: Bundle.main.url(
                    forResource: "UserRequestClassifier",
                    withExtension: "mlmodelc"
                )!
            )
        ) else {
            return .text
        }
        // Pre-process prompt to drop all trailing punctuation and convert to lowercase
        let processedPrompt: String = prompt.trimmingCharacters(
            in: .punctuationCharacters
        ).lowercased()
        // Run classifier
        let hypotheses: [String: Double] = promptClassifier.predictedLabelHypotheses(
            for: processedPrompt,
            maximumCount: ResultType.allCases.count
        )
        let textGenScore: Double = hypotheses[ResultType.text.rawValue] ?? 1.0
        let imageGenScore: Double = hypotheses[ResultType.image.rawValue] ?? 1.0
        // Get most likely result type
        let mostLikelyResultType: ResultType = {
            if textGenScore > imageGenScore {
                return .text
            }
            return .image
        }()
        // If score is similar or if prompt was too short to confirm need for image, prompt user
        var wantedResultType: ResultType? = nil
		let similarThreshold = 0.3
        let scoreWasSimilar: Bool = abs(textGenScore - imageGenScore) < similarThreshold
        let promptWasTooShort: Bool = processedPrompt.count < 50 && mostLikelyResultType == .image
        if scoreWasSimilar || promptWasTooShort {
			// Prompt user
			let _ = Dialogs.dichotomy(
				title: String(localized: "Response"),
				message: String(localized: "What do you want Sidekick to respond with?"),
				option1: String(localized: "Text"),
				option2: String(localized: "Image")
			) {
				wantedResultType = .text
			} ifOption2: {
				wantedResultType = .image
			}
			return wantedResultType!
		} else {
			// Return most likely type
			return mostLikelyResultType
		}
	}
	
	/// The expected result type of a prompt
	public enum ResultType: String, CaseIterable {
		
		init?(
			_ rawValue: String
		) {
			if let resultType: ResultType = Self.allCases.filter({ type in
				type.rawValue == rawValue
			}).first {
				self = resultType
			} else {
				return nil
			}
		}
		
		case text = "text-generation"
		case image = "image-generation"
		
		/// A `Bool` value indicating whether the result type is available
		public var isAvailable: Bool {
			switch self {
				case .text:
					return true
				case .image:
					// Check if Image Playground functionality is available
					if #available(macOS 15.2, *) {
						return ImagePlaygroundViewController.isAvailable
					} else {
						return false
					}
			}
		}
	}
    
}
