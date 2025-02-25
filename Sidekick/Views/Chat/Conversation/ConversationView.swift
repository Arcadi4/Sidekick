//
//  ConversationView.swift
//  Sidekick
//
//  Created by Bean John on 10/8/24.
//

import SwiftUI
import ImagePlayground

struct ConversationView: View {
	
	@StateObject private var promptController: PromptController = .init()
	
	@EnvironmentObject private var conversationManager: ConversationManager
	@EnvironmentObject private var expertManager: ExpertManager
	@EnvironmentObject private var conversationState: ConversationState
	
	var body: some View {
		Group {
			if #available(macOS 15.2, *) {
				messages
					.imagePlaygroundSheet(
						isPresented: self.$promptController.isGeneratingImage,
						// Image playground concepts
						concepts: [
							ImagePlaygroundConcept.extracted(
								from: self.promptController.imageConcept ?? "",
								title: nil
							)
						]
					) { url in
						// Save the image to the conversation
						self.addImageToConversation(url)
					} onCancellation: {
						self.cancelImageGeneration()
					}
			} else {
				messages
			}
		}
		.environmentObject(promptController)
	}
	
	var messages: some View {
		MessagesView()
			.padding(.leading)
			.overlay(alignment: .bottom) {
				ConversationControlsView()
					.padding(.trailing, 30)
			}
	}
	
	/// Function to add an image to the current conversation
	private func addImageToConversation(
		_ imageUrl: URL
	) {
		// Copy image
		let copiedImageDir: URL = Settings.containerUrl.appendingPathComponent(
			"Generated Images"
		)
		let copiedImageUrl: URL = copiedImageDir.appendingPathComponent(
			imageUrl.lastPathComponent
		)
		try? FileManager.default.createDirectory(
			at: copiedImageDir,
			withIntermediateDirectories: true
		)
		try? FileManager.default.copyItem(at: imageUrl, to: copiedImageUrl)
		// Formulate message
		let message: Message = Message(
			imageUrl: copiedImageUrl,
			prompt: self.promptController.imageConcept ?? ""
		)
		// Add message to conversation
		guard let currentConversationId: UUID = conversationState
			.selectedConversationId else {
			print("Could not get conversation id")
			return
		}
		guard var currentConversation: Conversation = conversationManager
			.getConversation(
			id: currentConversationId
			) else {
			print("Could not get conversation")
			return
		}
		let _ = currentConversation.addMessage(message)
		// Save
		withAnimation(.linear) {
			self.conversationManager.update(currentConversation)
		}
	}
	
	/// Function to handle image generation cancellation
	private func cancelImageGeneration() {
		// Remove previous message from conversation
		guard let currentConversationId: UUID = conversationState
			.selectedConversationId else {
			print("Could not get conversation id")
			return
		}
		guard var currentConversation: Conversation = conversationManager
			.getConversation(
				id: currentConversationId
			) else {
			print("Could not get conversation")
			return
		}
		currentConversation.dropLastMessage()
		// Save
		withAnimation(.linear) {
			self.conversationManager.update(currentConversation)
		}
	}
	
}
