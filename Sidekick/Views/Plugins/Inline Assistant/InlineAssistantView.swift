//
//  InlineAssistantView.swift
//  Sidekick
//
//  Created by Bean John on 11/18/24.
//

import SwiftUI

struct InlineAssistantView: View {
	
	var selectedText: String
	
	@StateObject private var model: Model = .shared
	
	@StateObject private var commandManager: CommandManager = .shared
	@StateObject private var inlineAssistantController: InlineAssistantController = .shared
	
	@State private var didSelectCommand: Bool = false
	@State private var isAddingCommand: Bool = false
	
	var body: some View {
		VStack(
			alignment: .center
		) {
			HStack {
				Text("Commands")
					.font(.title2)
					.bold()
				Spacer()
				ExitButton {
					self.inlineAssistantController.toggleInlineAssistant()
				}
			}
			.padding(.bottom, 8)
			self.commands
			Group {
				if self.didSelectCommand {
					self.progressIndicator
				} else {
					self.newCommandButton
				}
			}
			.padding(.top, 12)
		}
		.frame(minWidth: 500, maxWidth: 800)
		.padding(12)
		.padding(.bottom, 3)
		.background(
			.ultraThinMaterial,
			in: RoundedRectangle(cornerRadius: 10)
		)
		.onAppear {
			didSelectCommand = false
		}
		.sheet(isPresented: $isAddingCommand) {
			NewCommandView(isAddingCommand: $isAddingCommand)
				.frame(minWidth: 350, minHeight: 300)
		}
		.environmentObject(commandManager)
		.environmentObject(model)
	}
	
	var commands: some View {
		WrappingHStack(
			alignment: .leading,
			horizontalSpacing: 20
		) {
			ForEach(
				$commandManager.commands
			) { command in
				CommandButton(
					command: command
				) {
					self.executeCommand(command: command.wrappedValue)
				}
				.disabled(didSelectCommand)
			}
		}
	}
	
	var progressIndicator: some View {
		HStack {
			Text("Processing...")
			ProgressView()
				.progressViewStyle(.circular)
				.scaleEffect(0.5, anchor: .center)
		}
	}
	
	var newCommandButton: some View {
		Button {
			self.isAddingCommand.toggle()
		} label: {
			Label("Add Command", systemImage: "plus")
		}
		.buttonStyle(PlainButtonStyle())
	}
	
	private func executeCommand(
		command: Command
	) {
		// Toggle command selection
		didSelectCommand = true
		// Formulate message
		let systemPromptMessage: Message = Message(
			text: InferenceSettings.systemPrompt,
			sender: .system
		)
		let commandMessage: Message = Message(
			text: "\(command.prompt) Respond in plain text. DO NOT use Markdown. \n\n\(selectedText)",
			sender: .user
		)
		// Process completion
		Task.detached { @MainActor in
			// Get response
			let _ = try await self.model.listenThinkRespond(
				messages: [
					systemPromptMessage,
					commandMessage
				],
				mode: .default,
				handleResponseUpdate: { pendingMessage, partialResponse in
					self.handleResponseUpdate(
						pendingMessage: pendingMessage,
						partialResponse: partialResponse
					)
				},
				handleResponseFinish: { fullMessage, pendingMessage in
					self.handleResponseFinish(
						fullMessage: fullMessage,
						pendingMessage: pendingMessage
					)
				}
			)
		}
	}
	
	private func handleResponseUpdate(
		pendingMessage: String,
		partialResponse: String
	) {
		if self.inlineAssistantController.isShowing {
			self.inlineAssistantController.toggleInlineAssistant()
		}
		Accessibility.shared.simulateTyping(for: partialResponse)
	}
	
	private func handleResponseFinish(
		fullMessage: String,
		pendingMessage: String
	) {
		// Type it out
		let delta: String = fullMessage.replacingOccurrences(
			of: pendingMessage,
			with: ""
		)
		// If delta is reasonable
		if delta.count < 40 {
			Accessibility.shared.simulateTyping(for: delta)
		}
	}

}

#Preview {
	InlineAssistantView(
		selectedText: "Test text"
	)
}
