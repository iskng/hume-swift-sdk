import Foundation

public extension ToolCallMessage {
    /// Public initializer for ToolCallMessage
    init(
        customSessionId: String? = nil,
        name: String,
        parameters: String,
        responseRequired: Bool,
        toolCallId: String,
        toolType: ToolType? = nil
    ) {
        self.customSessionId = customSessionId
        self.name = name
        self.parameters = parameters
        self.responseRequired = responseRequired
        self.toolCallId = toolCallId
        self.toolType = toolType
        self.type = "tool_call"
    }
}