//
//  FunctionCall.swift
//  Sidekick
//
//  Created by John Bean on 4/8/25.
//

import Foundation
import SwiftUI

protocol AnyFunctionBox {
    
    var name: String { get }
    var params: [FunctionParameter] { get }
    
    func getJsonSchema() -> String
    func call(withData data: Data) async throws -> String?
    
    var functionCallType: DecodableFunctionCall.Type { get }
    
}

public struct FunctionCallRecord: Codable, Equatable, Hashable {
    
    /// The function call's ID
    var id: UUID = UUID()
    /// A `String` for the name of the function called
    var name: String
    /// A ``Status`` representing if the function was executed successfully
    var status: Status? = .executing
    /// A `Date` for the time where the function was called
    var timeCalled: Date = .now
    /// A `String` containing the result of the run
    var result: String? = nil
    
    public enum Status: Codable, CaseIterable {
        
        case succeeded
        case failed
        case executing
        
        var color: Color {
            switch self {
                case .succeeded:
                    return .brightGreen
                case .failed:
                    return .red
                case .executing:
                    return .secondary
            }
        }
    }
}
