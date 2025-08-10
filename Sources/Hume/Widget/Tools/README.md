# Tool Calling in Hume SDK

The Hume SDK provides comprehensive support for tool calling, allowing EVI to invoke custom functions in your application.

## Quick Start

```swift
// 1. Initialize VoiceProvider with tool configuration
let toolConfig = ToolManager.Configuration(
    timeout: 30,
    autoExecute: true,
    maxConcurrentExecutions: 3
)

let voiceProvider = VoiceProvider(
    client: humeClient,
    toolConfiguration: toolConfig
)

// 2. Register a simple tool
voiceProvider.tools.register("get_time") { _ in
    return """
    {"current_time": "\(Date())"}
    """
}

// 3. Register a typed tool
struct WeatherParams: Codable {
    let location: String
}

struct WeatherResult: Codable {
    let temperature: Double
    let condition: String
}

voiceProvider.tools.register(
    "get_weather",
    parameterType: WeatherParams.self,
    resultType: WeatherResult.self
) { params in
    // Your weather API call here
    return WeatherResult(temperature: 72.5, condition: "Sunny")
}
```

## Features

### Thread-Safe Tool Management
- Concurrent read/write protection
- Safe registration/unregistration during execution
- Automatic cleanup on disconnect

### Flexible Registration Options
- Raw JSON string handlers for maximum flexibility
- Typed handlers with automatic JSON encoding/decoding
- Built-in tool helpers for common tools
- Batch registration methods

### Execution Control
- Configurable timeouts with automatic cancellation
- Maximum concurrent execution limits
- Delegate callbacks for monitoring and control
- Manual vs automatic execution modes

### Built-in Tool Support
```swift
// Web Search
voiceProvider.tools.registerWebSearch { params in
    // Implement your search logic
    return ToolManager.WebSearchResult(...)
}

// Hang Up
voiceProvider.tools.registerHangUp { params in
    // Handle hang up request
    return ToolManager.HangUpResult(success: true)
}
```

## Manual Tool Handling

For complete control over tool execution:

```swift
// Disable automatic execution
voiceProvider.tools.configuration.autoExecute = false

// Handle tool calls manually in your delegate
func voiceProvider(_ provider: VoiceProvidable, didProduceEvent event: SubscribeEvent) {
    if case .toolCallMessage(let call) = event {
        Task {
            // Custom handling logic
            let response = ToolResponseMessage(...)
            try await provider.sendToolResponse(response)
        }
    }
}
```

## Delegate Integration

Monitor and control tool execution:

```swift
extension MyClass: VoiceProviderDelegate {
    func voiceProvider(_ provider: VoiceProvidable, shouldExecuteTool call: ToolCallMessage) -> Bool {
        // Decide whether to allow execution
        return allowedTools.contains(call.name)
    }
    
    func voiceProvider(_ provider: VoiceProvidable, didExecuteTool call: ToolCallMessage, result: ToolManager.ExecutionResult) {
        // Log or handle completion
        print("Tool \(call.name) completed: \(result)")
    }
}
```

## Architecture

### Components
- **ToolManager**: Thread-safe tool registry and executor
- **VoiceProvider**: Integration point with EVI WebSocket
- **ToolCallMessage**: Incoming tool request from EVI
- **ToolResponseMessage**: Success response to EVI
- **ToolErrorMessage**: Error response to EVI

### Execution Flow
1. EVI sends `tool_call` event
2. VoiceProvider receives and delegates to ToolManager
3. ToolManager executes registered handler with timeout
4. Result sent back to EVI as `tool_response` or `tool_error`
5. Delegate notified of completion

## Best Practices

1. **Always register tools before connecting** to ensure they're available when needed
2. **Use typed handlers** when possible for type safety
3. **Set appropriate timeouts** based on your tool's expected execution time
4. **Handle errors gracefully** - return meaningful error messages
5. **Clean up resources** in tool handlers if interrupted
6. **Test timeout scenarios** to ensure robust error handling

## Testing

See `ToolManagerTests.swift` for comprehensive test examples including:
- Registration and unregistration
- Successful execution
- Error handling
- Timeout scenarios
- Concurrent execution limits
- Delegate callbacks

.