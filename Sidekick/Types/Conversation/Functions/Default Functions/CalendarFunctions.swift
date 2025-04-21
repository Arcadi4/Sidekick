//
//  CalendarFunctions.swift
//  Sidekick
//
//  Created by John Bean on 4/17/25.
//

import EventKit
import Foundation

public class CalendarFunctions {
    
    static var functions: [AnyFunctionBox] = [
        CalendarFunctions.getEvents,
        CalendarFunctions.addEvent,
        CalendarFunctions.removeEvent,
        CalendarFunctions.editEvent
    ]
    
    /// An object representing an ``Event``
    public struct Event: Identifiable, Codable {
        
        init(
            event: EKEvent
        ) {
            self.title = event.title
            self.eventIdentifier = event.eventIdentifier
            self.isAllDay = event.isAllDay
            self.startDate = event.startDate.toString(
                dateFormat: "yyyy-MM-dd HH:mm:ss"
            )
            self.endDate = event.endDate.toString(
                dateFormat: "yyyy-MM-dd HH:mm:ss"
            )
            self.organizer = event.organizer?.name
            self.availability = event.availability.description
            self.status = event.status.description
        }
        
        public var id: String { self.eventIdentifier }
        
        var title: String
        var startDate: String
        var endDate: String
        var isAllDay: Bool
        var organizer: String?
        var availability: String?
        var status: String?
        var eventIdentifier: String
        
    }
    
    /// A set of errors applicable to multiple calendar functions
    public enum CalendarFunctionsError: LocalizedError {
        case noPermissions
        case invalidDateFormat
        case eventNotFound(String)
        case failedToSaveEvent(Error)
        public var errorDescription: String? {
            switch self {
                case .invalidDateFormat:
                    return "Invalid date format"
                case .noPermissions:
                    return "Permissions to access calendar was denied"
                case .eventNotFound(let id):
                    return "Event with identifier `\(id)` not found"
                case .failedToSaveEvent(let error):
                    return "Failed to save event: \(error.localizedDescription)"
            }
        }
    }
    
    /// A function to request full access to the user's calendar
    /// - Returns: A boolean indicating whether access was granted.
    private static func requestCalendarAccess() async -> Bool {
        let eventStore = EKEventStore()
        return await withCheckedContinuation { continuation in
            eventStore.requestFullAccessToEvents { granted, error in
                continuation.resume(returning: granted)
            }
        }
    }
    
    /// A function to convert strings to dates
    private static func convertStringToDate(
        _ input: String
    ) throws -> Date {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        // Check if date can be extracted
        if let date = dateFormatter.date(from: input) {
            return date
        } else {
            throw CalendarFunctionsError.invalidDateFormat
        }
    }
    
    /// A ``Function`` for getting the all events between 2 dates, inclusive
    static let getEvents = Function<GetEventsParams, String>(
        name: "get_events",
        description: "Get all events between the provided start and end dates, inclusive.",
        clearance: .dangerous,
        params: [
            FunctionParameter(
                label: "start_date",
                description: "The start date, in the format `yyyy-MM-dd HH:mm:ss`",
                datatype: .string,
                isRequired: true
            ),
            FunctionParameter(
                label: "end_date",
                description: "The end date, in the format `yyyy-MM-dd HH:mm:ss`",
                datatype: .string,
                isRequired: true
            )
        ],
        run: { params in
            // Check permissions
            if await !CalendarFunctions.requestCalendarAccess() {
                throw CalendarFunctionsError.noPermissions
            }
            // Get start and end date
            let startDate: Date = try CalendarFunctions.convertStringToDate(
                params.start_date
            )
            let endDate: Date = try CalendarFunctions.convertStringToDate(
                params.end_date
            )
            // Get events
            let eventStore: EKEventStore = EKEventStore()
            // All calendars that can contain events
            let calendars: [EKCalendar] = eventStore.calendars(
                for: .event
            )
            // Create the predicate for the date range
            let predicate = eventStore.predicateForEvents(
                withStart: startDate,
                end: endDate,
                calendars: calendars
            )
            // Fetch events
            let events: [Event] = eventStore.events(
                matching: predicate
            ).map { event in
                return CalendarFunctions.Event(event: event)
            }
            // Encode and return
            let jsonEncoder: JSONEncoder = JSONEncoder()
            jsonEncoder.outputFormatting = [.prettyPrinted]
            let jsonData: Data = try jsonEncoder.encode(events)
            return String(data: jsonData, encoding: .utf8)!
        }
    )
    struct GetEventsParams: FunctionParams {
        var start_date: String
        var end_date: String
    }
    
    /// A ``Function`` for adding an event to the user's calendar
    static let addEvent = Function<AddEventParams, String>(
        name: "add_event",
        description: "Add a new event to the user's calendar.",
        clearance: .sensitive,
        params: [
            FunctionParameter(
                label: "title",
                description: "The title of the event.",
                datatype: .string,
                isRequired: true
            ),
            FunctionParameter(
                label: "start_date",
                description: "The start date/time of the event, in the format `yyyy-MM-dd HH:mm:ss`.",
                datatype: .string,
                isRequired: true
            ),
            FunctionParameter(
                label: "end_date",
                description: "The end date/time of the event, in the format `yyyy-MM-dd HH:mm:ss`. (optional, defaults to one hour after startDate)",
                datatype: .string,
                isRequired: false
            ),
            FunctionParameter(
                label: "is_all_day",
                description: "Whether the event is an all day event.",
                datatype: .boolean,
                isRequired: false
            ),
            FunctionParameter(
                label: "notes",
                description: "Notes or description for the event.",
                datatype: .string,
                isRequired: false
            ),
            FunctionParameter(
                label: "location",
                description: "Event location.",
                datatype: .string,
                isRequired: false
            ),
            FunctionParameter(
                label: "ignore_conflicts",
                description: "Schedule the event even if it conflicts with existing events. (optional, defaults to false)",
                datatype: .boolean,
                isRequired: false
            )
        ],
        run: { params in
            // Check permissions
            if await !CalendarFunctions.requestCalendarAccess() {
                throw CalendarFunctionsError.noPermissions
            }
            let eventStore = EKEventStore()
            let calendars = eventStore.calendars(for: .event)
            // Use default calendar for new events
            guard let calendar = eventStore.defaultCalendarForNewEvents ?? calendars.first else {
                throw CalendarFunctionsError.noPermissions // Fallback - could make a new error type
            }
            let event = EKEvent(eventStore: eventStore)
            event.calendar = calendar
            event.title = params.title
            // Set event date
            let startDate = try CalendarFunctions.convertStringToDate(
                params.start_date
            )
            let endDate: Date
            if let userEndDate = params.end_date {
                endDate = try CalendarFunctions.convertStringToDate(userEndDate)
            } else {
                // Add 1 hour
                endDate = startDate.addingTimeInterval(3600)
            }
            event.startDate = startDate
            event.endDate = endDate
            event.isAllDay = params.is_all_day ?? false
            if let notes = params.notes {
                event.notes = notes
            }
            if let location = params.location {
                event.location = location
            }
            
            // Check for conflicts
            let ignoreConflicts = params.ignore_conflicts ?? false
            if !ignoreConflicts {
                // Check for any overlapping events
                let predicate = eventStore.predicateForEvents(
                    withStart: startDate,
                    end: endDate,
                    calendars: [calendar]
                )
                let existingEvents = eventStore.events(matching: predicate)
                // Filter out events that are all day if the new event is not all day, and vice versa.
                if let conflicting = existingEvents.first(where: {
                    $0.eventIdentifier != event.eventIdentifier &&
                    $0.isAllDay == event.isAllDay &&
                    $0.startDate < endDate && $0.endDate > startDate
                }) {
                    let dateFormatter = DateFormatter()
                    dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
                    let conflictStart = dateFormatter.string(from: conflicting.startDate)
                    let conflictEnd = dateFormatter.string(from: conflicting.endDate)
                    throw AddEventError.eventConflict(
                        conflictingEventName: conflicting.title ?? "Unnamed Event",
                        conflictingEventStart: conflictStart,
                        conflictingEventEnd: conflictEnd
                    )
                }
            }
            
            do {
                try eventStore.save(event, span: .thisEvent, commit: true)
            } catch {
                throw CalendarFunctionsError.failedToSaveEvent(error)
            }
            // Return the created event as JSON
            let createdEvent = CalendarFunctions.Event(event: event)
            let jsonEncoder = JSONEncoder()
            jsonEncoder.outputFormatting = [.prettyPrinted]
            let jsonData = try jsonEncoder.encode(createdEvent)
            return String(data: jsonData, encoding: .utf8)!
            // Error
            enum AddEventError: LocalizedError {
                case eventConflict(
                    conflictingEventName: String,
                    conflictingEventStart: String,
                    conflictingEventEnd: String
                )
                public var errorDescription: String? {
                    switch self {
                        case .eventConflict(let name, let start, let end):
                            return "Time conflicts with existing event: \"\(name)\" (\(start) - \(end))"
                    }
                }
            }
        }
    )
    struct AddEventParams: FunctionParams {
        var title: String
        var start_date: String
        var end_date: String?
        var is_all_day: Bool?
        var notes: String?
        var location: String?
        var ignore_conflicts: Bool?
    }
    
    /// A ``Function`` to remove an event by its identifier.
    static let removeEvent = Function<RemoveEventParams, String>(
        name: "remove_event",
        description: "Remove an event from the user's calendar by its event UUID. Call `get_events` to find the UUID of an event.",
        clearance: .dangerous,
        params: [
            FunctionParameter(
                label: "eventIdentifier",
                description: "The unique UUID for the event.",
                datatype: .string,
                isRequired: true
            )
        ],
        run: { params in
            // Check permissions
            if await !CalendarFunctions.requestCalendarAccess() {
                throw CalendarFunctionsError.noPermissions
            }
            let eventStore = EKEventStore()
            guard let event = eventStore.event(withIdentifier: params.eventIdentifier) else {
                throw CalendarFunctionsError.eventNotFound(params.eventIdentifier)
            }
            do {
                try eventStore.remove(event, span: .thisEvent, commit: true)
            } catch {
                throw CalendarFunctionsError.failedToSaveEvent(error)
            }
            // Optionally, return the identifier or confirmation message as JSON
            let result = ["removedEventIdentifier": params.eventIdentifier]
            let jsonEncoder = JSONEncoder()
            let jsonData = try jsonEncoder.encode(result)
            return String(data: jsonData, encoding: .utf8)!
        }
    )
    struct RemoveEventParams: FunctionParams {
        var eventIdentifier: String
    }
    
    /// A ``Function`` to edit an event by its identifier.
    static let editEvent = Function<EditEventParams, String>(
        name: "edit_event",
        description: "Edit an existing event in the user's calendar by its UUID. Only provided fields will be updated. Call `get_events` to find the UUID of an event.",
        clearance: .dangerous,
        params: [
            FunctionParameter(
                label: "eventIdentifier",
                description: "The UUID of the event to edit.",
                datatype: .string,
                isRequired: true
            ),
            FunctionParameter(
                label: "title",
                description: "The new title of the event.",
                datatype: .string,
                isRequired: false
            ),
            FunctionParameter(
                label: "startDate",
                description: "The new start date/time of the event, in the format `yyyy-MM-dd HH:mm:ss`.",
                datatype: .string,
                isRequired: false
            ),
            FunctionParameter(
                label: "endDate",
                description: "The new end date/time of the event, in the format `yyyy-MM-dd HH:mm:ss`.",
                datatype: .string,
                isRequired: false
            ),
            FunctionParameter(
                label: "isAllDay",
                description: "Whether the event is an all day event.",
                datatype: .boolean,
                isRequired: false
            ),
            FunctionParameter(
                label: "notes",
                description: "Notes or description for the event.",
                datatype: .string,
                isRequired: false
            ),
            FunctionParameter(
                label: "location",
                description: "Event location.",
                datatype: .string,
                isRequired: false
            )
        ],
        run: { params in
            // Check permissions
            if await !CalendarFunctions.requestCalendarAccess() {
                throw CalendarFunctionsError.noPermissions
            }
            let eventStore = EKEventStore()
            guard let event = eventStore.event(withIdentifier: params.eventIdentifier) else {
                throw CalendarFunctionsError.eventNotFound(params.eventIdentifier)
            }
            // Update event fields if provided
            if let title = params.title {
                event.title = title
            }
            if let startDateStr = params.startDate {
                event.startDate = try CalendarFunctions.convertStringToDate(startDateStr)
            }
            if let endDateStr = params.endDate {
                event.endDate = try CalendarFunctions.convertStringToDate(endDateStr)
            }
            if let isAllDay = params.isAllDay {
                event.isAllDay = isAllDay
            }
            if let notes = params.notes {
                event.notes = notes
            }
            if let location = params.location {
                event.location = location
            }
            // Save changes
            do {
                try eventStore.save(event, span: .thisEvent, commit: true)
            } catch {
                throw CalendarFunctionsError.failedToSaveEvent(error)
            }
            // Return the updated event as JSON
            let updatedEvent = CalendarFunctions.Event(event: event)
            let jsonEncoder = JSONEncoder()
            jsonEncoder.outputFormatting = [.prettyPrinted]
            let jsonData = try jsonEncoder.encode(updatedEvent)
            return String(data: jsonData, encoding: .utf8)!
        }
    )
    struct EditEventParams: FunctionParams {
        var eventIdentifier: String
        var title: String?
        var startDate: String?
        var endDate: String?
        var isAllDay: Bool?
        var notes: String?
        var location: String?
    }
    
}
