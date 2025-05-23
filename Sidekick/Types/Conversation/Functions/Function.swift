//
//  Function.swift
//  Sidekick
//
//  Created by John Bean on 4/7/25.
//

import Foundation
import LocalAuthentication
import SwiftUI

// MARK: Function Call Decoder
public protocol DecodableFunctionCall: Decodable {
    
    static func parse(from data: Data, using decoder: JSONDecoder) -> Self?
    
    var name: String { get }
    
    mutating func call() async throws -> String?
    func getJsonSchema() -> String
    
}

// MARK: - Updated Function Parameter
public struct FunctionParameter: Codable {
    
    var label: String
    var description: String
    var datatype: Datatype
    var isRequired: Bool = true
    
    public enum Datatype: String, Codable {
        case string
        case integer
        case float
        case boolean
        case stringArray
        case integerArray
        case floatArray
    }
    
    /// Helper function to get the Swift type for a Datatype
    func getSwiftType() -> Any.Type {
        switch datatype {
            case .string:
                return String.self
            case .integer:
                return Int.self
            case .float:
                return Float.self
            case .boolean:
                return Bool.self
            case .stringArray:
                return [String].self
            case .integerArray:
                return [Int].self
            case .floatArray:
                return [Float].self
        }
    }
}

// MARK: - Function Protocol
protocol FunctionProtocol: Identifiable {
    
    associatedtype Parameters
    associatedtype Result
    
    var id: String { get }
    var name: String { get }
    var description: String { get }
    var params: [FunctionParameter] { get }
    var run: (Parameters) async throws -> Result { get }
    
    func getJsonSchema() -> String
    
}

// MARK: - Generic Function Implementation
public struct Function<Parameter: FunctionParams, Result>: FunctionProtocol, AnyFunctionBox {

    public var id: String { return name }
    
    public var name: String
    public var description: String
    public var clearance: Clearance
    
    public var params: [FunctionParameter]
    public var run: (Parameter) async throws -> Result
    
    public var paramType: Codable.Type
    
    public init(
        name: String,
        description: String,
        clearance: Clearance = .regular,
        params: [FunctionParameter],
        run: @escaping (Parameter) async throws -> Result
    ) {
        self.name = name
        self.description = description
        self.clearance = clearance
        self.params = params
        self.paramType = Parameter.self
        self.run = run
    }
    
    public var functionObject: FunctionObject {
        // Create numbered properties to ensure order
        let properties = Dictionary(uniqueKeysWithValues: params.enumerated().map { index, param in
            let numberedKey = String(format: "%04d_%@", index, param.label)
            return (numberedKey, FunctionObject.Function.InputSchema.Property(
                type: param.datatype.rawValue,
                description: param.description,
                isRequired: param.isRequired
            ))
        })
        
        return FunctionObject(
            type: "function",
            function: FunctionObject.Function(
                name: self.name,
                description: self.description,
                inputSchema: FunctionObject.Function.InputSchema(
                    type: "object",
                    properties: properties,
                    paramLabels: params.map { $0.label }
                )
            )
        )
    }
    
    /// A function to get the function's JSON schema to inject into the system prompt
    public func getJsonSchema() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let jsonData = try! encoder.encode(self.functionObject)
        let jsonStr = String(data: jsonData, encoding: .utf8)!
        // Process the JSON to remove the number prefixes
        return cleanNumberedKeys(jsonStr)
    }
    
    private func cleanNumberedKeys(_ jsonStr: String) -> String {
        // Remove the numbered prefixes from property keys
        var lines = jsonStr.components(separatedBy: .newlines)
        lines = lines.map { line in
            if line.contains("\"0") { // Matches our numbered format
                let components = line.split(separator: "\"", omittingEmptySubsequences: false)
                if components.count >= 2 {
                    var key = String(components[1])
                    if let underscoreIndex = key.firstIndex(of: "_") {
                        key = String(key[key.index(after: underscoreIndex)...])
                        return line.replacingOccurrences(of: components[1], with: key)
                    }
                }
            }
            return line
        }
        return lines.joined(separator: "\n")
    }
    
    /// A function to call the function
    public func call(
        withData data: Data
    ) async throws -> String? {
        // Decode the provided arguments to the generic Parameter type
        let params: Parameter = try JSONDecoder().decode(
            Parameter.self,
            from: data
        )
        // Ask for permissions if needed
        let requestDescription: String = String(localized: """
Sidekick wants to run the function `\(self.name)` to complete your request with the parameters below.

\(String(data: data, encoding: .utf8)!)

Do you wish to permit this?
""")
        switch self.clearance {
            case .regular:
                break
            case .sensitive:
                // Ask with dialog
                if await !Dialogs.showConfirmation(
                    title: String(localized: "Function Use"),
                    message: requestDescription
                ) {
                    // If denied, throw error
                    throw FunctionCallError.permissionsDenied
                }
            case .dangerous:
                // Ask for identification
                let context: LAContext = LAContext()
                let policy: LAPolicy = LAPolicy.deviceOwnerAuthentication
                let result = try await context.evaluatePolicy(
                    policy,
                    localizedReason: requestDescription
                )
        }
        // Execute the wrapped run closure.
        let result = try await run(params)
        return String(describing: result)
    }
    
    public enum Clearance: String, CaseIterable {
        case regular
        case sensitive
        case dangerous
    }
    
    public enum FunctionCallError: String, Error {
        case permissionsDenied = "The user denied your request to use this tool."
    }
    
    public struct FunctionObject: Codable {
        
        var type: String = "function"
        var function: Function
        
        public struct Function: Codable {
            
            var name: String
            var description: String
            var inputSchema: InputSchema
            
            public struct InputSchema: Codable {
                
                let type: String
                let properties: [String: Property]
                var required: [String]
                private let paramLabels: [String]
                
                init(
                    type: String,
                    properties: [String: Property],
                    paramLabels: [String]
                ) {
                    self.type = type
                    self.properties = properties
                    self.paramLabels = paramLabels
                    // Compute required preserving the original param order
                    self.required = paramLabels.filter { label in
                        // Find the numbered key that ends with this label
                        properties.first { key, prop in
                            key.hasSuffix("_\(label)") && prop.isRequired
                        } != nil
                    }
                }
                
                public func encode(to encoder: Encoder) throws {
                    var container = encoder.container(keyedBy: CodingKeys.self)
                    try container.encode(type, forKey: .type)
                    try container.encode(properties, forKey: .properties)
                    // Encode required without number prefixes
                    try container.encode(required, forKey: .required)
                }
                
                public init(from decoder: Decoder) throws {
                    let container = try decoder.container(keyedBy: CodingKeys.self)
                    self.type = try container.decode(String.self, forKey: .type)
                    self.properties = try container.decode([String: Property].self, forKey: .properties)
                    self.required = try container.decode([String].self, forKey: .required)
                    self.paramLabels = self.required.isEmpty ? Array(properties.keys) : self.required
                }
                
                public enum CodingKeys: String, CodingKey {
                    case type, properties, required
                }
                
                public struct Property: Codable {
                    let type: String
                    let description: String
                    let isRequired: Bool
                }
                
            }
            
        }
        
    }
    
    public var functionCallType: DecodableFunctionCall.Type {
        return Self.FunctionCall.self
    }
    
    public struct FunctionCall: Codable, Equatable, Hashable, DecodableFunctionCall {
        
        /// Function to conform to equatable
        public static func == (lhs: FunctionCall, rhs: FunctionCall) -> Bool {
            return lhs.config == rhs.config
        }
        
        /// The name of the function
        public var name: String {
            return self.config.name
        }
        /// The function call's configuration
        let config: FunctionCallConfig
        
        // Custom coding keys to match both possible JSON structures
        enum CodingKeys: String, CodingKey {
            case functionCall = "function_call"
            case function = "function"
        }
        
        // Custom decoding initialization to handle both keys
        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            
            // Try decoding using function_call first, then function
            if let config = try? container.decode(FunctionCallConfig.self, forKey: .functionCall) {
                self.config = config
            } else if let config = try? container.decode(FunctionCallConfig.self, forKey: .function) {
                self.config = config
            } else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: container.codingPath,
                        debugDescription: "Neither 'function_call' nor 'function' key found in JSON"
                    )
                )
            }
        }
        
        // Custom encoding to use function_call key
        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(config, forKey: .functionCall)
        }
        
        /// Function to call the function
        mutating public func call() async throws -> String? {
            // Locate the function by name
            guard let function = DefaultFunctions.functions.first(
                where: { $0.name == self.config.name }
            ) else {
                throw FunctionCallError.functionNotFound
            }
            // Instead of expecting a raw type (like a tuple or a simple String), we are using Codable structs for parameters
            let encoder: JSONEncoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            let argumentData: Data = try encoder.encode(self.config.arguments)
            // Use the type erased call method.
            return try await function.call(withData: argumentData)
        }
        
        /// Function to convert the function call to JSON
        public func getJsonSchema() -> String {
            let encoder: JSONEncoder = JSONEncoder()
            let jsonData: Data? = try? encoder.encode(self)
            return String(data: jsonData!, encoding: .utf8)!
        }
        
        /// Function to decode the function from data
        public static func parse(
            from data: Data,
            using decoder: JSONDecoder
        ) -> Function<Parameter, Result>.FunctionCall? {
            return try? decoder.decode(
                Function<Parameter, Result>.FunctionCall.self,
                from: data
            )
        }
        
        public enum FunctionCallError: String, Error {
            case functionNotFound = "The function called is not available"
        }
        
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
        
        public struct FunctionCallConfig: Codable, Hashable {
            
            public static func == (lhs: Function<Parameter, Result>.FunctionCall.FunctionCallConfig, rhs: Function<Parameter, Result>.FunctionCall.FunctionCallConfig) -> Bool {
                return lhs.name == rhs.name
            }
            
            let name: String
            let arguments: Parameter
            
        }
        
    }
    
}

// MARK: - Parameter Parsing Error
enum ParameterParsingError: Error {
    case invalidArrayFormat(String)
    case incompatibleType(String)
    case invalidValue(String)
}
