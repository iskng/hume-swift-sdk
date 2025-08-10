import Foundation

/// Helper extensions for built-in tools
public extension ToolManager {
    
    // MARK: - Web Search
    
    /// Parameters for the web_search built-in tool
    struct WebSearchParams: Codable {
        public let query: String
        
        public init(query: String) {
            self.query = query
        }
    }
    
    /// Result for the web_search built-in tool
    struct WebSearchResult: Codable {
        public let results: [SearchResult]
        public let query: String
        
        public struct SearchResult: Codable {
            public let title: String
            public let url: String
            public let snippet: String
            
            public init(title: String, url: String, snippet: String) {
                self.title = title
                self.url = url
                self.snippet = snippet
            }
        }
        
        public init(results: [SearchResult], query: String) {
            self.results = results
            self.query = query
        }
    }
    
    /// Register a handler for the web_search built-in tool
    /// - Parameter handler: Async closure that performs the web search
    func registerWebSearch(
        handler: @escaping (WebSearchParams) async throws -> WebSearchResult
    ) {
        register(
            BuiltInTool.webSearch.rawValue,
            parameterType: WebSearchParams.self,
            resultType: WebSearchResult.self,
            handler: handler
        )
    }
    
    // MARK: - Hang Up
    
    /// Parameters for the hang_up built-in tool
    struct HangUpParams: Codable {
        public let reason: String?
        
        public init(reason: String? = nil) {
            self.reason = reason
        }
    }
    
    /// Result for the hang_up built-in tool
    struct HangUpResult: Codable {
        public let success: Bool
        public let message: String?
        
        public init(success: Bool, message: String? = nil) {
            self.success = success
            self.message = message
        }
    }
    
    /// Register a handler for the hang_up built-in tool
    /// - Parameter handler: Async closure that handles the hang up request
    func registerHangUp(
        handler: @escaping (HangUpParams) async throws -> HangUpResult
    ) {
        register(
            BuiltInTool.hangUp.rawValue,
            parameterType: HangUpParams.self,
            resultType: HangUpResult.self,
            handler: handler
        )
    }
}

// MARK: - Convenience Registration Methods

public extension ToolManager {
    
    /// Register multiple tools at once
    func registerTools(_ tools: [(name: String, handler: ToolHandler)]) {
        for (name, handler) in tools {
            register(name, handler: handler)
        }
    }
    
    /// Register a simple tool that takes no parameters and returns a string
    func registerSimpleTool(
        _ name: String,
        handler: @escaping () async throws -> String
    ) {
        register(name) { _ in
            try await handler()
        }
    }
    
    /// Register a synchronous tool (wrapped in async)
    func registerSyncTool(
        _ name: String,
        handler: @escaping (String) throws -> String
    ) {
        register(name) { params in
            try handler(params)
        }
    }
}

// MARK: - Common Tool Templates

public extension ToolManager {
    
    /// Parameters for a weather lookup tool
    struct WeatherParams: Codable {
        public let location: String
        public let units: String?
        
        public init(location: String, units: String? = "celsius") {
            self.location = location
            self.units = units
        }
    }
    
    /// Result for a weather lookup tool
    struct WeatherResult: Codable {
        public let temperature: Double
        public let condition: String
        public let humidity: Int?
        public let windSpeed: Double?
        
        public init(
            temperature: Double,
            condition: String,
            humidity: Int? = nil,
            windSpeed: Double? = nil
        ) {
            self.temperature = temperature
            self.condition = condition
            self.humidity = humidity
            self.windSpeed = windSpeed
        }
    }
    
    /// Register a weather lookup tool
    func registerWeatherTool(
        name: String = "get_weather",
        handler: @escaping (WeatherParams) async throws -> WeatherResult
    ) {
        register(
            name,
            parameterType: WeatherParams.self,
            resultType: WeatherResult.self,
            handler: handler
        )
    }
    
    /// Parameters for a calculation tool
    struct CalculationParams: Codable {
        public let expression: String
        
        public init(expression: String) {
            self.expression = expression
        }
    }
    
    /// Result for a calculation tool
    struct CalculationResult: Codable {
        public let result: Double
        public let formattedResult: String
        
        public init(result: Double, formattedResult: String? = nil) {
            self.result = result
            self.formattedResult = formattedResult ?? String(result)
        }
    }
    
    /// Register a calculation tool
    func registerCalculatorTool(
        name: String = "calculate",
        handler: @escaping (CalculationParams) async throws -> CalculationResult
    ) {
        register(
            name,
            parameterType: CalculationParams.self,
            resultType: CalculationResult.self,
            handler: handler
        )
    }
}