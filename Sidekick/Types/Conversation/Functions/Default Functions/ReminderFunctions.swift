//
//  RemindersFunctions.swift
//  Sidekick
//
//  Created by John Bean on 4/17/25.
//

import EventKit
import Foundation

public class RemindersFunctions {
    
    static var functions: [AnyFunctionBox] = [
        RemindersFunctions.getReminders,
        RemindersFunctions.addReminder,
        RemindersFunctions.removeReminder,
        RemindersFunctions.editReminder
    ]
    
    /// An object representing a ``Reminder``
    public struct Reminder: Identifiable, Codable {
        
        init(
            reminder: EKReminder
        ) {
            self.title = reminder.title
            self.reminderIdentifier = reminder.calendarItemIdentifier
            self.dueDate = reminder.dueDateComponents?.date?.toString(dateFormat: "yyyy-MM-dd HH:mm:ss")
            self.isCompleted = reminder.isCompleted
            self.notes = reminder.notes
            self.priority = {
                switch reminder.priority {
                    case 1:
                        return "High"
                    case 5:
                        return "Medium"
                    case 9:
                        return "Low"
                    default:
                        return "None"
                }
            }()
            self.completionDate = reminder.completionDate?.toString(dateFormat: "yyyy-MM-dd HH:mm:ss")
        }
        
        public var id: String { self.reminderIdentifier }
        
        var title: String
        var dueDate: String?
        var isCompleted: Bool
        var notes: String?
        var priority: String
        var completionDate: String?
        var reminderIdentifier: String
        
    }
    
    /// A set of errors applicable to multiple reminder functions
    public enum RemindersFunctionsError: LocalizedError {
        
        case noPermissions
        case invalidDateFormat
        case reminderNotFound(String)
        case failedToSaveReminder(Error)
        
        public var errorDescription: String? {
            switch self {
                case .invalidDateFormat:
                    return "Invalid date format"
                case .noPermissions:
                    return "Permissions to access reminders was denied"
                case .reminderNotFound(let id):
                    return "Reminder with identifier '\(id)' not found"
                case .failedToSaveReminder(let error):
                    return "Failed to save reminder: \(error.localizedDescription)"
            }
        }
        
    }
    
    /// A function to request full access to the user's reminders
    /// - Returns: A boolean indicating whether access was granted.
    private static func requestRemindersAccess() async -> Bool {
        let eventStore = EKEventStore()
        return await withCheckedContinuation { continuation in
            eventStore.requestFullAccessToReminders { granted, error in
                continuation.resume(returning: granted)
            }
        }
    }
    
    /// A function to convert strings to dates
    private static func convertStringToDate(_ input: String) throws -> Date {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        if let date = dateFormatter.date(from: input) {
            return date
        } else {
            throw RemindersFunctionsError.invalidDateFormat
        }
    }
    
    /// A ``Function`` for getting all reminders, optionally filtered by completion state and due date range
    static let getReminders = Function<GetRemindersParams, String>(
        name: "get_reminders",
        description: "Get all reminders, optionally filtering by completion and due date range.",
        clearance: .sensitive,
        params: [
            FunctionParameter(
                label: "completed",
                description: "Whether to include completed reminders (optional, defaults to false).",
                datatype: .boolean,
                isRequired: false
            ),
            FunctionParameter(
                label: "startDueDate",
                description: "The start due date, format `yyyy-MM-dd HH:mm:ss` (optional).",
                datatype: .string,
                isRequired: false
            ),
            FunctionParameter(
                label: "endDueDate",
                description: "The end due date, format `yyyy-MM-dd HH:mm:ss` (optional).",
                datatype: .string,
                isRequired: false
            )
        ],
        run: { params in
            // Ask for permissions
            if await !RemindersFunctions.requestRemindersAccess() {
                throw RemindersFunctionsError.noPermissions
            }
            let eventStore = EKEventStore()
            let predicate: NSPredicate
            let calendars = eventStore.calendars(for: .reminder)
            // Build predicate for date range or all reminders
            if let startDue = params.startDueDate, let endDue = params.endDueDate {
                let startDate = try RemindersFunctions.convertStringToDate(startDue)
                let endDate = try RemindersFunctions.convertStringToDate(endDue)
                predicate = eventStore.predicateForIncompleteReminders(
                    withDueDateStarting: startDate,
                    ending: endDate,
                    calendars: calendars
                )
            } else {
                predicate = eventStore.predicateForReminders(in: calendars)
            }
            
            // Fetch reminders (async API)
            let reminders = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[EKReminder], Error>) in
                eventStore.fetchReminders(matching: predicate) { reminders in
                    continuation.resume(returning: reminders ?? [])
                }
            }
            
            let filteredReminders: [Reminder]
            if let completed = params.completed {
                filteredReminders = reminders
                    .filter { $0.isCompleted == completed }
                    .map { Reminder(reminder: $0) }
            } else {
                filteredReminders = reminders.map { Reminder(reminder: $0) }
            }
            
            let jsonEncoder: JSONEncoder = JSONEncoder()
            jsonEncoder.outputFormatting = [.prettyPrinted]
            let jsonData: Data = try jsonEncoder.encode(filteredReminders)
            return String(data: jsonData, encoding: .utf8)!
        }
    )
    struct GetRemindersParams: FunctionParams {
        var completed: Bool?
        var startDueDate: String?
        var endDueDate: String?
    }
    
    /// A ``Function`` for adding a reminder to the user's reminders
    static let addReminder = Function<AddReminderParams, String>(
        name: "add_reminder",
        description: "Add a new reminder to the user's reminders list.",
        clearance: .sensitive,
        params: [
            FunctionParameter(
                label: "title",
                description: "The title of the reminder.",
                datatype: .string,
                isRequired: true
            ),
            FunctionParameter(
                label: "dueDate",
                description: "The due date/time for the reminder, format `yyyy-MM-dd HH:mm:ss` (optional).",
                datatype: .string,
                isRequired: false
            ),
            FunctionParameter(
                label: "notes",
                description: "Notes or description for the reminder.",
                datatype: .string,
                isRequired: false
            ),
            FunctionParameter(
                label: "priority",
                description: "The priority of the reminder (0 = none, 1 = high, 5 = medium, 9 = low, optional).",
                datatype: .integer,
                isRequired: false
            )
        ],
        run: { params in
            if await !RemindersFunctions.requestRemindersAccess() {
                throw RemindersFunctionsError.noPermissions
            }
            let eventStore = EKEventStore()
            let calendars = eventStore.calendars(for: .reminder)
            guard let calendar = eventStore.defaultCalendarForNewReminders() ?? calendars.first else {
                throw RemindersFunctionsError.noPermissions // Could introduce a new error type here
            }
            // Create reminder
            let reminder = EKReminder(eventStore: eventStore)
            reminder.calendar = calendar
            reminder.title = params.title
            if let dueDateString = params.dueDate {
                let dueDate = try RemindersFunctions.convertStringToDate(dueDateString)
                reminder.dueDateComponents = Calendar.current.dateComponents(
                    [.year, .month, .day, .hour, .minute, .second],
                    from: dueDate
                )
            }
            if let notes = params.notes {
                reminder.notes = notes
            }
            if let priority = params.priority {
                reminder.priority = priority
            }
            // Create reminder
            do {
                try eventStore.save(reminder, commit: true)
            } catch {
                throw RemindersFunctionsError.failedToSaveReminder(error)
            }
            // Returned the created reminder as JSON
            let createdReminder = RemindersFunctions.Reminder(reminder: reminder)
            let jsonEncoder = JSONEncoder()
            jsonEncoder.outputFormatting = [.prettyPrinted]
            let jsonData = try jsonEncoder.encode(createdReminder)
            return String(data: jsonData, encoding: .utf8)!
        }
    )
    struct AddReminderParams: FunctionParams {
        var title: String
        var dueDate: String?
        var notes: String?
        var priority: Int?
    }
    
    /// A ``Function`` for removing a reminder by its identifier
    static let removeReminder = Function<RemoveReminderParams, String>(
        name: "remove_reminder",
        description: "Remove a reminder by its identifier. Call `get_reminders` to find the UUID of a reminder.",
        clearance: .sensitive,
        params: [
            FunctionParameter(
                label: "reminderIdentifier",
                description: "The UUID of the reminder to remove.",
                datatype: .string,
                isRequired: true
            )
        ],
        run: { params in
            if await !RemindersFunctions.requestRemindersAccess() {
                throw RemindersFunctionsError.noPermissions
            }
            let eventStore = EKEventStore()
            let calendars = eventStore.calendars(for: .reminder)
            let predicate = eventStore.predicateForReminders(in: calendars)
            let reminders = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[EKReminder], Error>) in
                eventStore.fetchReminders(matching: predicate) { reminders in
                    continuation.resume(returning: reminders ?? [])
                }
            }
            guard let reminder = reminders.first(where: { $0.calendarItemIdentifier == params.reminderIdentifier }) else {
                throw RemindersFunctionsError.reminderNotFound(params.reminderIdentifier)
            }
            // Formulate success message
            var successMessage: String = "The reminder was removed successfully"
            if let name = reminder.title {
                successMessage = "The reminder `\(name)` was removed successfully"
            }
            // Remove reminder
            do {
                try eventStore.remove(reminder, commit: true)
            } catch {
                throw RemindersFunctionsError.failedToSaveReminder(error)
            }
            return successMessage
        }
    )
    struct RemoveReminderParams: FunctionParams {
        var reminderIdentifier: String
    }
    
    /// A ``Function`` for editing an existing reminder by its identifier
    static let editReminder = Function<EditReminderParams, String>(
        name: "edit_reminder",
        description: "Edit an existing reminder by its UUID. You can update the title, due date, notes, completion status, or priority. Call `get_reminders` to find the UUID of a reminder.",
        clearance: .sensitive,
        params: [
            FunctionParameter(
                label: "reminderIdentifier",
                description: "The UUID of the reminder to edit.",
                datatype: .string,
                isRequired: true
            ),
            FunctionParameter(
                label: "title",
                description: "The new title for the reminder (optional).",
                datatype: .string,
                isRequired: false
            ),
            FunctionParameter(
                label: "dueDate",
                description: "The new due date/time for the reminder, format `yyyy-MM-dd HH:mm:ss` (optional).",
                datatype: .string,
                isRequired: false
            ),
            FunctionParameter(
                label: "notes",
                description: "The new notes or description for the reminder (optional).",
                datatype: .string,
                isRequired: false
            ),
            FunctionParameter(
                label: "isCompleted",
                description: "Whether the reminder is completed (optional).",
                datatype: .boolean,
                isRequired: false
            ),
            FunctionParameter(
                label: "priority",
                description: "The new priority of the reminder (0 = none, 1 = high, 5 = medium, 9 = low, optional).",
                datatype: .integer,
                isRequired: false
            )
        ],
        run: { params in
            // Check permissions
            if await !RemindersFunctions.requestRemindersAccess() {
                throw RemindersFunctions.RemindersFunctionsError.noPermissions
            }
            // Get reminders
            let eventStore = EKEventStore()
            let calendars = eventStore.calendars(for: .reminder)
            let predicate = eventStore.predicateForReminders(in: calendars)
            let reminders = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[EKReminder], Error>) in
                eventStore.fetchReminders(matching: predicate) { reminders in
                    continuation.resume(returning: reminders ?? [])
                }
            }
            guard let reminder = reminders.first(where: { $0.calendarItemIdentifier == params.reminderIdentifier }) else {
                throw RemindersFunctionsError.reminderNotFound(params.reminderIdentifier)
            }
            // Update fields if provided
            if let title = params.title {
                reminder.title = title
            }
            if let dueDateString = params.dueDate {
                let dueDate = try RemindersFunctions.convertStringToDate(dueDateString)
                reminder.dueDateComponents = Calendar.current.dateComponents(
                    [.year, .month, .day, .hour, .minute, .second],
                    from: dueDate
                )
            }
            if let notes = params.notes {
                reminder.notes = notes
            }
            if let isCompleted = params.isCompleted {
                reminder.isCompleted = isCompleted
                if isCompleted {
                    reminder.completionDate = Date()
                } else {
                    reminder.completionDate = nil
                }
            }
            if let priority = params.priority {
                reminder.priority = priority
            }
            // Save changes
            do {
                try eventStore.save(reminder, commit: true)
            } catch {
                throw RemindersFunctions.RemindersFunctionsError.failedToSaveReminder(error)
            }
            // Return the updated reminder as JSON
            let updatedReminder = RemindersFunctions.Reminder(reminder: reminder)
            let jsonEncoder = JSONEncoder()
            jsonEncoder.outputFormatting = [.prettyPrinted]
            let jsonData = try jsonEncoder.encode(updatedReminder)
            return String(data: jsonData, encoding: .utf8)!
        }
    )
    struct EditReminderParams: FunctionParams {
        var reminderIdentifier: String
        var title: String?
        var dueDate: String?
        var notes: String?
        var isCompleted: Bool?
        var priority: Int?
    }
    
}
