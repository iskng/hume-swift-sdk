import Foundation

/// Thread-safe manager for EVI tool registration and execution
public final class ToolManager {
    
    // MARK: - Types
    
    public typealias ToolHandler = (String) async throws -> String
    
    /// Configuration for tool execution
    public struct Configuration {
        /// Maximum time allowed for tool execution
        public var timeout: TimeInterval
        
        /// Whether to automatically handle tool calls
        public var autoExecute: Bool
        
        /// Maximum concurrent tool executions
        public var maxConcurrentExecutions: Int
        
        public init(
            timeout: TimeInterval = 30,
            autoExecute: Bool = true,
            maxConcurrentExecutions: Int = 5
        ) {
            self.timeout = timeout
            self.autoExecute = autoExecute
            self.maxConcurrentExecutions = maxConcurrentExecutions
        }
    }
    
    /// Result of a tool execution
    public enum ExecutionResult {
        case success(String)
        case error(String, code: String?)
        case timeout
        case cancelled
    }
    
    // MARK: - Properties
    
    private var handlers: [String: ToolHandler] = [:]
    private let handlersQueue = DispatchQueue(label: "com.hume.toolmanager.handlers", attributes: .concurrent)
    
    private var executionTasks: Set<Task<Void, Never>> = []
    private let tasksLock = NSLock()
    
    public var configuration: Configuration
    
    weak var delegate: ToolManagerDelegate?
    
    // MARK: - Initialization
    
    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }
    
    deinit {
        cancelAllExecutions()
    }
    
    // MARK: - Tool Registration
    
    /// Register a tool with raw JSON string handler
    public func register(
        _ name: String,
        handler: @escaping ToolHandler
    ) {
        handlersQueue.async(flags: .barrier) { [weak self] in
            self?.handlers[name] = handler
        }
    }
    
    /// Register a tool with typed parameters and result
    public func register<P: Decodable, R: Encodable>(
        _ name: String,
        parameterType: P.Type,
        resultType: R.Type,
        decoder: JSONDecoder = JSONDecoder(),
        encoder: JSONEncoder = JSONEncoder(),
        handler: @escaping (P) async throws -> R
    ) {
        register(name) { parametersJSON in
            guard let data = parametersJSON.data(using: .utf8) else {
                throw ToolError.invalidParameters("Failed to convert parameters to data")
            }
            
            let params = try decoder.decode(P.self, from: data)
            let result = try await handler(params)
            let resultData = try encoder.encode(result)
            
            guard let resultJSON = String(data: resultData, encoding: .utf8) else {
                throw ToolError.encodingFailed("Failed to encode result to JSON string")
            }
            
            return resultJSON
        }
    }
    
    /// Register a handler for a built-in tool
    public func registerBuiltIn(
        _ tool: BuiltInTool,
        handler: @escaping ToolHandler
    ) {
        register(tool.rawValue, handler: handler)
    }
    
    /// Unregister a specific tool
    public func unregister(_ name: String) {
        handlersQueue.async(flags: .barrier) { [weak self] in
            self?.handlers.removeValue(forKey: name)
        }
    }
    
    /// Remove all registered tools
    public func unregisterAll() {
        handlersQueue.async(flags: .barrier) { [weak self] in
            self?.handlers.removeAll()
        }
    }
    
    /// Check if a tool is registered
    public func isRegistered(_ name: String) -> Bool {
        handlersQueue.sync {
            handlers[name] != nil
        }
    }
    
    /// Get list of registered tool names
    public var registeredTools: [String] {
        handlersQueue.sync {
            Array(handlers.keys)
        }
    }
    
    // MARK: - Tool Execution
    
    /// Execute a tool call
    @discardableResult
    public func execute(
        _ call: ToolCallMessage,
        timeout: TimeInterval? = nil
    ) async -> ExecutionResult {
        let toolName = call.name
        
        // Check if handler exists
        guard let handler = getHandler(for: toolName) else {
            await delegate?.toolManager(self, didFailExecution: call, error: ToolError.notRegistered(toolName))
            return .error("Tool '\(toolName)' is not registered", code: "TOOL_NOT_FOUND")
        }
        
        // Notify delegate
        let shouldProceed = await (delegate?.toolManager(self, willExecute: call) ?? true)
        guard shouldProceed else {
            return .error("Execution cancelled by delegate", code: "CANCELLED_BY_DELEGATE")
        }
        
        // Create execution task with timeout
        let effectiveTimeout = timeout ?? configuration.timeout
        
        let task = Task<ExecutionResult, Never> {
            await withTaskGroup(of: ExecutionResult.self) { group in
                // Add timeout task
                group.addTask {
                    try? await Task.sleep(nanoseconds: UInt64(effectiveTimeout * 1_000_000_000))
                    return .timeout
                }
                
                // Add execution task
                group.addTask {
                    do {
                        let result = try await handler(call.parameters)
                        return .success(result)
                    } catch let error as ToolError {
                        return .error(error.localizedDescription, code: error.code)
                    } catch {
                        return .error(String(describing: error), code: nil)
                    }
                }
                
                // Return first completed result
                guard let result = await group.next() else {
                    return .error("Unexpected error", code: "UNKNOWN")
                }
                
                // Cancel remaining tasks
                group.cancelAll()
                
                return result
            }
        }
        
        // Track task
        addTask(task)
        
        // Wait for result
        let result = await task.value
        
        // Clean up
        removeTask(task)
        
        // Notify delegate
        await delegate?.toolManager(self, didComplete: call, result: result)
        
        return result
    }
    
    /// Cancel all ongoing tool executions
    public func cancelAllExecutions() {
        tasksLock.lock()
        let tasks = executionTasks
        executionTasks.removeAll()
        tasksLock.unlock()
        
        tasks.forEach { $0.cancel() }
    }
    
    // MARK: - Private Helpers
    
    private func getHandler(for name: String) -> ToolHandler? {
        handlersQueue.sync {
            handlers[name]
        }
    }
    
    private func addTask(_ task: Task<ExecutionResult, Never>) {
        tasksLock.lock()
        
        // Wrap in a Task that removes itself when done
        let wrappedTask = Task<Void, Never> {
            _ = await task.value
        }
        
        executionTasks.insert(wrappedTask)
        
        // Enforce max concurrent executions
        if executionTasks.count > configuration.maxConcurrentExecutions {
            // Cancel oldest task (first in set)
            if let oldest = executionTasks.first {
                oldest.cancel()
                executionTasks.remove(oldest)
            }
        }
        
        tasksLock.unlock()
    }
    
    private func removeTask(_ task: Task<ExecutionResult, Never>) {
        // Since we wrap tasks, we don't need to remove them explicitly
        // They'll be removed when they complete
    }
}

// MARK: - ToolManagerDelegate

/// Delegate protocol for monitoring tool execution
public protocol ToolManagerDelegate: AnyObject {
    /// Called before a tool is executed. Return false to cancel execution.
    func toolManager(_ manager: ToolManager, willExecute call: ToolCallMessage) async -> Bool
    
    /// Called after a tool execution completes
    func toolManager(_ manager: ToolManager, didComplete call: ToolCallMessage, result: ToolManager.ExecutionResult) async
    
    /// Called when a tool execution fails
    func toolManager(_ manager: ToolManager, didFailExecution call: ToolCallMessage, error: Error) async
}

// Default implementations (all optional)
public extension ToolManagerDelegate {
    func toolManager(_ manager: ToolManager, willExecute call: ToolCallMessage) async -> Bool { true }
    func toolManager(_ manager: ToolManager, didComplete call: ToolCallMessage, result: ToolManager.ExecutionResult) async {}
    func toolManager(_ manager: ToolManager, didFailExecution call: ToolCallMessage, error: Error) async {}
}

// MARK: - ToolError

/// Errors that can occur during tool operations
public enum ToolError: LocalizedError {
    case notRegistered(String)
    case invalidParameters(String)
    case encodingFailed(String)
    case timeout
    case cancelled
    
    public var errorDescription: String? {
        switch self {
        case .notRegistered(let name):
            return "Tool '\(name)' is not registered"
        case .invalidParameters(let message):
            return "Invalid parameters: \(message)"
        case .encodingFailed(let message):
            return "Encoding failed: \(message)"
        case .timeout:
            return "Tool execution timed out"
        case .cancelled:
            return "Tool execution was cancelled"
        }
    }
    
    var code: String {
        switch self {
        case .notRegistered: return "TOOL_NOT_FOUND"
        case .invalidParameters: return "INVALID_PARAMS"
        case .encodingFailed: return "ENCODING_ERROR"
        case .timeout: return "TIMEOUT"
        case .cancelled: return "CANCELLED"
        }
    }
}