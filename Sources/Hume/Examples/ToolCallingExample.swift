import Foundation

/// Example demonstrating how to use the tool calling functionality in the Hume SDK
public class ToolCallingExample {
    
    private let humeClient: HumeClient
    private let voiceProvider: VoiceProvider
    
    public init(accessToken: String) {
        // Initialize with tool configuration
        let toolConfig = ToolManager.Configuration(
            timeout: 30,  // 30 second timeout for tools
            autoExecute: true,  // Automatically execute registered tools
            maxConcurrentExecutions: 3  // Allow up to 3 tools to run at once
        )
        
        self.humeClient = HumeClient(options: .accessToken(token: accessToken))
        self.voiceProvider = VoiceProvider(
            client: humeClient,
            toolConfiguration: toolConfig
        )
        
        // Set up tool handlers
        setupTools()
    }
    
    private func setupTools() {
        // Example 1: Simple tool with raw JSON
        voiceProvider.tools.register("get_time") { _ in
            let formatter = ISO8601DateFormatter()
            let now = formatter.string(from: Date())
            return """
            {
                "current_time": "\(now)",
                "timezone": "\(TimeZone.current.identifier)"
            }
            """
        }
        
        // Example 2: Typed tool with parameters
        struct MathParams: Codable {
            let operation: String
            let a: Double
            let b: Double
        }
        
        struct MathResult: Codable {
            let result: Double
            let expression: String
        }
        
        voiceProvider.tools.register(
            "calculator",
            parameterType: MathParams.self,
            resultType: MathResult.self
        ) { params in
            let result: Double
            let expression: String
            
            switch params.operation {
            case "add":
                result = params.a + params.b
                expression = "\(params.a) + \(params.b)"
            case "subtract":
                result = params.a - params.b
                expression = "\(params.a) - \(params.b)"
            case "multiply":
                result = params.a * params.b
                expression = "\(params.a) × \(params.b)"
            case "divide":
                guard params.b != 0 else {
                    throw ToolError.invalidParameters("Cannot divide by zero")
                }
                result = params.a / params.b
                expression = "\(params.a) ÷ \(params.b)"
            default:
                throw ToolError.invalidParameters("Unknown operation: \(params.operation)")
            }
            
            return MathResult(result: result, expression: expression)
        }
        
        // Example 3: Built-in web search tool
        voiceProvider.tools.registerWebSearch { params in
            // In a real app, you would call an actual search API here
            print("Searching for: \(params.query)")
            
            // Mock search results
            let results = [
                ToolManager.WebSearchResult.SearchResult(
                    title: "Example Result 1",
                    url: "https://example.com/1",
                    snippet: "This is a sample search result for \(params.query)"
                ),
                ToolManager.WebSearchResult.SearchResult(
                    title: "Example Result 2",
                    url: "https://example.com/2",
                    snippet: "Another sample result related to \(params.query)"
                )
            ]
            
            return ToolManager.WebSearchResult(
                results: results,
                query: params.query
            )
        }
        
        // Example 4: Built-in hang up tool
        voiceProvider.tools.registerHangUp { params in
            print("Hang up requested. Reason: \(params.reason ?? "No reason provided")")
            
            // Disconnect the voice provider
            Task {
                await self.voiceProvider.disconnect()
            }
            
            return ToolManager.HangUpResult(
                success: true,
                message: "Call ended successfully"
            )
        }
        
        // Example 5: Weather tool using the template
        voiceProvider.tools.registerWeatherTool { params in
            // Mock weather API call
            print("Getting weather for: \(params.location)")
            
            return ToolManager.WeatherResult(
                temperature: 22.5,
                condition: "Partly cloudy",
                humidity: 65,
                windSpeed: 12.3
            )
        }
        
        // Example 6: Async tool with external API call
        voiceProvider.tools.register("fetch_data") { parametersJSON in
            // Parse parameters
            guard let data = parametersJSON.data(using: .utf8),
                  let params = try? JSONDecoder().decode([String: String].self, from: data),
                  let endpoint = params["endpoint"] else {
                throw ToolError.invalidParameters("Missing endpoint parameter")
            }
            
            // Make async network call
            let url = URL(string: endpoint)!
            let (responseData, _) = try await URLSession.shared.data(from: url)
            
            // Return the response as JSON string
            return String(data: responseData, encoding: .utf8) ?? "{}"
        }
    }
    
    /// Example of manual tool handling (when autoExecute is false)
    public func setupManualToolHandling() {
        // Disable auto-execution
        voiceProvider.tools.configuration.autoExecute = false
        
        // Set up delegate to handle tool calls manually
        voiceProvider.delegate = self
    }
    
    /// Example of using the tool manager directly
    public func demonstrateDirectToolExecution() async {
        // Create a mock tool call message
        let mockCall = ToolCallMessage(
            customSessionId: nil,
            name: "calculator",
            parameters: """
            {
                "operation": "add",
                "a": 5,
                "b": 3
            }
            """,
            responseRequired: true,
            toolCallId: "test-123",
            toolType: nil,
            type: "tool_call"
        )
        
        // Execute the tool directly
        let result = await voiceProvider.tools.execute(mockCall, timeout: 10)
        
        switch result {
        case .success(let content):
            print("Tool executed successfully: \(content)")
        case .error(let message, let code):
            print("Tool error: \(message) (code: \(code ?? "unknown"))")
        case .timeout:
            print("Tool execution timed out")
        case .cancelled:
            print("Tool execution was cancelled")
        }
    }
    
    /// Example of registering tools with different configurations
    public func demonstrateAdvancedToolRegistration() {
        // Register multiple tools at once
        voiceProvider.tools.registerTools([
            ("tool1", { _ in "Result 1" }),
            ("tool2", { _ in "Result 2" }),
            ("tool3", { _ in "Result 3" })
        ])
        
        // Register a simple tool with no parameters
        voiceProvider.tools.registerSimpleTool("ping") {
            return "pong"
        }
        
        // Register a synchronous tool
        voiceProvider.tools.registerSyncTool("echo") { params in
            return params  // Just echo back the parameters
        }
        
        // Check if a tool is registered
        if voiceProvider.tools.isRegistered("calculator") {
            print("Calculator tool is available")
        }
        
        // List all registered tools
        let registeredTools = voiceProvider.tools.registeredTools
        print("Registered tools: \(registeredTools.joined(separator: ", "))")
        
        // Unregister a specific tool
        voiceProvider.tools.unregister("tool1")
        
        // Clear all tools
        voiceProvider.tools.unregisterAll()
    }
}

// MARK: - VoiceProviderDelegate for Manual Tool Handling

extension ToolCallingExample: VoiceProviderDelegate {
    
    public func voiceProvider(_ voiceProvider: any VoiceProvidable, shouldExecuteTool call: ToolCallMessage) -> Bool {
        // You can decide whether to allow the tool execution
        print("Tool call received: \(call.name)")
        
        // Example: Only allow certain tools
        let allowedTools = ["calculator", "get_time", "weather"]
        return allowedTools.contains(call.name)
    }
    
    public func voiceProvider(_ voiceProvider: any VoiceProvidable, willExecuteTool call: ToolCallMessage) {
        print("About to execute tool: \(call.name)")
    }
    
    public func voiceProvider(_ voiceProvider: any VoiceProvidable, didExecuteTool call: ToolCallMessage, result: ToolManager.ExecutionResult) {
        print("Tool \(call.name) completed with result: \(result)")
    }
    
    public func voiceProvider(_ voiceProvider: any VoiceProvidable, didFailToolExecution call: ToolCallMessage, error: Error) {
        print("Tool \(call.name) failed: \(error)")
    }
    
    public func voiceProvider(_ voiceProvider: any VoiceProvidable, didProduceEvent event: SubscribeEvent) {
        // Handle tool call events when autoExecute is false
        if case .toolCallMessage(let call) = event {
            if !voiceProvider.tools.configuration.autoExecute {
                Task {
                    await handleManualToolCall(call, provider: voiceProvider)
                }
            }
        }
    }
    
    private func handleManualToolCall(_ call: ToolCallMessage, provider: any VoiceProvidable) async {
        do {
            // Custom logic for manual tool handling
            if call.name == "special_tool" {
                // Handle this tool specially
                let response = ToolResponseMessage(
                    content: """
                    {
                        "result": "Special handling applied",
                        "timestamp": "\(Date())"
                    }
                    """,
                    customSessionId: call.customSessionId,
                    toolCallId: call.toolCallId,
                    toolName: call.name,
                    toolType: call.toolType
                )
                try await provider.sendToolResponse(response)
            } else {
                // Use the registered handler if available
                let result = await provider.tools.execute(call)
                
                // Send the response based on the result
                switch result {
                case .success(let content):
                    let response = ToolResponseMessage(
                        content: content,
                        customSessionId: call.customSessionId,
                        toolCallId: call.toolCallId,
                        toolName: call.name,
                        toolType: call.toolType
                    )
                    try await provider.sendToolResponse(response)
                    
                case .error(let message, let code):
                    let error = ToolErrorMessage(
                        code: code,
                        content: nil,
                        customSessionId: call.customSessionId,
                        error: message,
                        level: .warn,
                        toolCallId: call.toolCallId,
                        toolType: call.toolType
                    )
                    try await provider.sendToolError(error)
                    
                default:
                    break
                }
            }
        } catch {
            print("Failed to handle tool call: \(error)")
        }
    }
}