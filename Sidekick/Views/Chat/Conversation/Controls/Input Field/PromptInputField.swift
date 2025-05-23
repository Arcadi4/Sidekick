//
//  PromptInputField.swift
//  Sidekick
//
//  Created by Bean John on 10/23/24.
//

import SwiftUI
import SimilaritySearchKit
import ImagePlayground

struct PromptInputField: View {
	
	@FocusState private var isFocused: Bool
	
	@EnvironmentObject private var model: Model
	@EnvironmentObject private var conversationManager: ConversationManager
	@EnvironmentObject private var expertManager: ExpertManager
	@EnvironmentObject private var conversationState: ConversationState
	@EnvironmentObject private var promptController: PromptController
	@EnvironmentObject private var canvasController: CanvasController
	
	var selectedConversation: Conversation? {
		guard let selectedConversationId = conversationState.selectedConversationId else {
			return nil
		}
		return self.conversationManager.getConversation(
			id: selectedConversationId
		)
	}
	
	var selectedExpert: Expert? {
		guard let selectedExpertId = conversationState.selectedExpertId else {
			return nil
		}
		return expertManager.getExpert(id: selectedExpertId)
	}
	
	var messages: [Message] {
		return selectedConversation?.messages ?? []
	}
	
	var showQuickPrompts: Bool {
		return promptController.prompt.isEmpty && messages.isEmpty
	}
	
	var addFilesTip: AddFilesTip = .init()
	
	var body: some View {
		textField
			.onExitCommand {
				self.isFocused = false
			}
			.onChange(
				of: isFocused
			) {
				// Show add files and dictation tips if needed
				if self.isFocused {
					AddFilesTip.readyForAddingFiles = true
				}
			}
			.onChange(
				of: conversationState.selectedConversationId
			) {
				self.isFocused = true
			}
			.onChange(
				of: conversationState.selectedExpertId
			) {
				// If web search can be used
				if RetrievalSettings.canUseWebSearch,
				   let useWebSearch = self.selectedExpert?.useWebSearch {
					// Sync web search settings
					withAnimation(.linear) {
						self.promptController.useWebSearch = useWebSearch
					}
				}
			}
			.onAppear {
				self.isFocused = true
			}
			.popoverTip(addFilesTip)
	}
	
	var textField: some View {
		TextField(
			"Send a Message",
			text: $promptController.prompt.animation(
				.linear
			),
			axis: .vertical
		)
		.onSubmit(onSubmit)
		.focused($isFocused)
		.textFieldStyle(
			ChatStyle(
				isFocused: _isFocused,
				isRecording: $promptController.isRecording,
				useAttachments: true,
				bottomOptions: true,
				cornerRadius: 22
			)
		)
		.overlay(alignment: .leading) {
			AttachmentSelectionButton { url in
				await self.promptController.addFile(url)
			}
		}
		.overlay(alignment: .trailing) {
			DictationButton()
		}
		.overlay(alignment: .bottomLeading) {
            HStack {
                UseWebSearchButton(
                    useWebSearch: self.$promptController.useWebSearch
                )
                UseFunctionsButton(
                    useFunctions: self.$promptController.useFunctions
                )
            }
			.padding(.leading, 32)
			.padding(.bottom, 10)
			.frame(height: 25)
		}
		.submitLabel(.send)
		.padding([.vertical, .leading], 10)
	}
	
	/// Function to run when the `return` key is hit
	private func onSubmit() {
		// New line if shift or option pressed
		if CGKeyCode.kVK_Shift.isPressed || CGKeyCode.kVK_Option.isPressed {
			promptController.prompt += "\n"
		} else if promptController.prompt.trimmingCharacters(in: .whitespacesAndNewlines) != "" {
			// End recording
			self.promptController.stopRecording()
			// Send message
			self.submit()
		}
	}
	
	/// Function to send to bot
	private func submit() {
		// Get previous content
		guard var conversation = selectedConversation else { return }
		// Check if last message was successful
		if let prevMessage: Message = conversation.messages.last {
			// If unsuccessful
			let wasAssistant: Bool = prevMessage.getSender() == .assistant
			if prevMessage.text.isEmpty && prevMessage.imageUrl == nil && wasAssistant {
				// Tell user to retry
				Dialogs.showAlert(
					title: String(localized: "Retry"),
					message: String(localized: "Please retry your previous message.")
				)
				return
			}
		}
		// Make sound
		if Settings.playSoundEffects {
			SoundEffects.send.play()
		}
		// Get prompt expected result type
		let resultType: PromptAnalyzer.ResultType = PromptAnalyzer.analyzePrompt(
			promptController.prompt
		)
		// Check web search
		if !self.checkWebSearch() {
			return
		}
		// Make request message
		let newUserMessage: Message = Message(
			text: promptController.prompt,
			sender: .user
		)
		let _ = conversation.addMessage(newUserMessage)
		conversationManager.update(conversation)
		// Store sent properties
		self.promptController.sentConversation = conversation
		self.promptController.sentExpertId = self.conversationState.selectedExpertId
		// Capture temp resources
		let tempResources: [TemporaryResource] = self.promptController.tempResources
		// If result type is text, send message
		switch resultType {
			case .text:
				self.startTextGeneration(
					prompt: promptController.prompt,
					tempResources: tempResources
				)
			case .image:
				// If image generation is available, start generating image
				if PromptAnalyzer.ResultType.image.isAvailable {
					self.startImageGeneration()
				} else {
					// Else, fall back to text
					self.startTextGeneration(
						prompt: promptController.prompt,
						tempResources: tempResources
					)
				}
		}
		// Clear prompt
		self.clearInputs()
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
			self.clearInputs()
		}
	}
	
	private func startTextGeneration(
		prompt: String,
		tempResources: [TemporaryResource]
	) {
		// Get response
		Task {
			await self.generateChatResponse(
				prompt: prompt,
				tempResources: tempResources
			)
		}
	}
	
	private func startImageGeneration() {
		if #available(macOS 15.2, *) {
			// Start generation
			self.promptController.imageConcept = self.promptController.prompt
			self.promptController.isGeneratingImage = true
			// Reset sent properties
			self.promptController.sentConversation = nil
		}
	}
	
	private func clearInputs() {
		self.promptController.prompt.removeAll()
	}
	
	private func generateChatResponse(
		prompt: String,
		tempResources: [TemporaryResource]
	) async {
		// If processing, use recursion to update
		if (model.status == .processing || model.status == .coldProcessing) {
			Task {
				await model.interrupt()
				Task.detached(priority: .userInitiated) {
					try? await Task.sleep(for: .seconds(1))
					await generateChatResponse(
						prompt: prompt,
						tempResources: tempResources
					)
				}
			}
			return
		}
		// Get and save conversation
		guard var conversation = self.promptController.sentConversation else { return }
		self.model.setSentConversationId(conversation.id)
		// Generate title & update again
		let isFirstMessage: Bool = conversation.messages.count <= 1
		if Settings.generateConversationTitles && isFirstMessage {
			self.model.indicateStartedNamingConversation()
			if let title = try? await self.generateConversationTitle(
				prompt: prompt
			), !title.isEmpty {
				conversation.title = title
			}
			withAnimation(.linear) {
				self.conversationManager.update(conversation)
			}
		}
		// Get response
		var response: LlamaServer.CompleteResponse
		var didUseSources: Bool = false
		do {
			self.model.indicateStartedQuerying()
			var index: SimilarityIndex? = nil
			// If there are resources
			if !((selectedExpert?.resources.resources.isEmpty) ?? true) {
				// Load
				index = await selectedExpert?.resources.loadIndex()
			}
			let useWebSearch: Bool = self.promptController.useWebSearch
			// Set if sources were used
			let hasIndexItems: Bool = !((
				index?.indexItems.isEmpty
			) ?? true)
			didUseSources = useWebSearch || hasIndexItems || !tempResources.isEmpty
			response = try await model.listenThinkRespond(
                messages: self.messages,
                modelType: .regular,
				mode: .chat,
				similarityIndex: index,
				useWebSearch: useWebSearch,
                useFunctions: self.promptController.useFunctions,
				useCanvas: self.conversationState.useCanvas,
				canvasSelection: self.canvasController.selection,
				temporaryResources: tempResources
			)
		} catch let error as LlamaServerError {
			await model.interrupt()
			self.handleResponseError(error)
			return
		} catch {
			print("Agent listen threw unexpected error", error as Any)
			return
		}
		// Update UI
		await MainActor.run {
			// Exit if conversation is inactive
			if self.selectedConversation?.id != conversation.id {
				return
			}
			// Output final output to debug console
			// Make response message
			var responseMessage: Message = Message(
				text: response.text,
				sender: .assistant,
				model: response.modelName,
                functionCallRecords: response.functionCalls,
				expertId: promptController.sentExpertId
			)
			responseMessage.update(
				response: response,
				includeReferences: didUseSources
			)
			responseMessage.end()
			// Update conversation
			let _ = conversation.addMessage(
				responseMessage
			)
			conversation.tokenCount = response.usage?.total_tokens
			self.conversationManager.update(conversation)
			// Make sound
			if Settings.playSoundEffects {
				SoundEffects.ping.play()
			}
			// Reset sentConversation
			self.promptController.sentConversation = nil
		}
	}
	
	/// Function to generate a title for the conversation
	private func generateConversationTitle(
		prompt: String
	) async throws -> String? {
		// Formulate messages
		let generateTitleMessage: Message = Message(
			text: """
A user is chatting with an assistant and they have sent the message below. Generate an extremely short label for the chat session. Actively remove details from the user's message to make the label shorter than 4 words. Respond with the label ONLY.

"\(prompt)"
""",
			sender: .user
		)
		let messages: [Message] = [
			generateTitleMessage
		]
		// Generate
		let title: String = try await model.listenThinkRespond(
			messages: messages,
			modelType: .worker,
			mode: .default
		).text
		// Reset pending message text
        self.model.pendingMessage = nil
		// Return
		return title
			.reasoningRemoved
			.trimmingWhitespaceAndNewlines()
			.capitalizeEachWord
			.dropPrefixIfPresent("\"")
			.dropSuffixIfPresent("\"")
	}
	
	@MainActor
	private func handleResponseError(_ error: LlamaServerError) {
		// Display error message
		let errorDescription: String = error.errorDescription ?? "Unknown Error"
		let recoverySuggestion: String = error.recoverySuggestion
		Dialogs.showAlert(
			title: errorDescription,
			message: recoverySuggestion
		)
		// Restore prompt
		if let prompt: String = self.promptController.sentConversation?.messages.last?.text {
			self.promptController.prompt = prompt
		}
		// Remove messages
		if let messages: [Message] = self.promptController.sentConversation?.messages.dropLast(1),
		   var conversation = self.promptController.sentConversation {
			// Drop message and update
			conversation.messages = messages
			self.conversationManager.update(conversation)
		}
		// Reset model status
		self.model.status = .ready
		self.model.sentConversationId = nil
	}
	
	/// Function to check if web search can be used
	private func checkWebSearch() -> Bool {
		// If web search is on, but cannot be used
		let success: Bool = !(!RetrievalSettings.canUseWebSearch && self.promptController.useWebSearch)
		if !success {
			// Show dialog
			Dialogs.showAlert(
				title: String(localized: "Search not configured"),
				message: String(localized: "Search is not configured. Please configure it in \"Settings\" -> \"Retrieval\".")
			)
			self.promptController.useWebSearch = false
		}
		return success
	}

}
