//
//  CommandEditorView.swift
//  Sidekick
//
//  Created by Bean John on 11/19/24.
//

import SwiftUI

struct CommandEditorView: View {
	
	@EnvironmentObject private var commandManager: CommandManager
	
	@Binding var command: Command
	@Binding var isEditingCommand: Bool
	
	var body: some View {
		VStack {
			HStack {
				ExitButton {
					self.isEditingCommand.toggle()
				}
				Spacer()
			}
			form
		}
		.padding()
	}
	
	var form: some View {
		Form {
			Section {
				VStack(
					alignment: .leading
				) {
					nameEditor
					promptEditor
				}
				.padding(.horizontal, 5)
			}
		}
		.formStyle(.grouped)
	}
	
	var nameEditor: some View {
		Group {
			HStack {
				VStack(alignment: .leading) {
					Text("Name")
						.font(.title3)
						.bold()
					Text("This command's name")
						.font(.caption)
				}
				Spacer()
				TextField("", text: $command.name)
					.textFieldStyle(.plain)
			}
		}
		.onChange(of: command.name) {
			self.commandManager.commands = self.commandManager.commands.sorted(by: \.name)
		}
	}
	
	var promptEditor: some View {
		Group {
			HStack(
				alignment: .top
			) {
				VStack(alignment: .leading) {
					Text("Prompt")
						.font(.title3)
						.bold()
					Text("This command's prompt")
						.font(.caption)
				}
				Spacer()
				TextEditor(text: $command.prompt)
					.frame(minHeight: 125)
			}
		}
	}
	
}
