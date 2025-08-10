import XCTest
@testable import Hume

final class ToolManagerTests: XCTestCase {
    
    var toolManager: ToolManager!
    
    override func setUp() {
        super.setUp()
        toolManager = ToolManager()
    }
    
    override func tearDown() {
        toolManager.cancelAllExecutions()
        toolManager = nil
        super.tearDown()
    }
    
    // MARK: - Registration Tests
    
    func testToolRegistration() {
        // Register a tool
        toolManager.register("test_tool") { _ in
            return "success"
        }
        
        XCTAssertTrue(toolManager.isRegistered("test_tool"))
        XCTAssertFalse(toolManager.isRegistered("non_existent"))
        XCTAssertEqual(toolManager.registeredTools, ["test_tool"])
    }
    
    func testToolUnregistration() {
        // Register tools
        toolManager.register("tool1") { _ in "1" }
        toolManager.register("tool2") { _ in "2" }
        
        XCTAssertEqual(toolManager.registeredTools.count, 2)
        
        // Unregister one
        toolManager.unregister("tool1")
        XCTAssertFalse(toolManager.isRegistered("tool1"))
        XCTAssertTrue(toolManager.isRegistered("tool2"))
        
        // Unregister all
        toolManager.unregisterAll()
        XCTAssertEqual(toolManager.registeredTools.count, 0)
    }
    
    func testTypedToolRegistration() {
        struct TestParams: Codable {
            let value: Int
        }
        
        struct TestResult: Codable {
            let doubled: Int
        }
        
        toolManager.register(
            "typed_tool",
            parameterType: TestParams.self,
            resultType: TestResult.self
        ) { params in
            TestResult(doubled: params.value * 2)
        }
        
        XCTAssertTrue(toolManager.isRegistered("typed_tool"))
    }
    
    // MARK: - Execution Tests
    
    func testSuccessfulToolExecution() async {
        let expectation = XCTestExpectation(description: "Tool executes successfully")
        
        toolManager.register("async_tool") { params in
            expectation.fulfill()
            return """
            {"result": "success", "params": \(params)}
            """
        }
        
        let call = createMockToolCall(name: "async_tool", parameters: """
            {"test": "value"}
            """)
        
        let result = await toolManager.execute(call)
        
        switch result {
        case .success(let content):
            XCTAssertTrue(content.contains("success"))
            XCTAssertTrue(content.contains("test"))
        default:
            XCTFail("Expected success, got \(result)")
        }
        
        await fulfillment(of: [expectation], timeout: 1.0)
    }
    
    func testToolNotRegisteredError() async {
        let call = createMockToolCall(name: "unregistered_tool", parameters: "{}")
        let result = await toolManager.execute(call)
        
        switch result {
        case .error(let message, let code):
            XCTAssertTrue(message.contains("not registered"))
            XCTAssertEqual(code, "TOOL_NOT_FOUND")
        default:
            XCTFail("Expected error for unregistered tool")
        }
    }
    
    func testToolExecutionTimeout() async {
        // Configure with very short timeout
        toolManager.configuration.timeout = 0.1
        
        toolManager.register("slow_tool") { _ in
            // Simulate slow operation
            try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
            return "Should not reach here"
        }
        
        let call = createMockToolCall(name: "slow_tool", parameters: "{}")
        let result = await toolManager.execute(call)
        
        switch result {
        case .timeout:
            // Success - tool timed out as expected
            break
        default:
            XCTFail("Expected timeout, got \(result)")
        }
    }
    
    func testToolExecutionError() async {
        enum TestError: Error {
            case intentionalError
        }
        
        toolManager.register("error_tool") { _ in
            throw TestError.intentionalError
        }
        
        let call = createMockToolCall(name: "error_tool", parameters: "{}")
        let result = await toolManager.execute(call)
        
        switch result {
        case .error(_, _):
            // Success - error was caught
            break
        default:
            XCTFail("Expected error result")
        }
    }
    
    // MARK: - Built-in Tool Tests
    
    func testBuiltInWebSearchRegistration() {
        toolManager.registerWebSearch { params in
            ToolManager.WebSearchResult(
                results: [
                    .init(
                        title: "Test",
                        url: "https://test.com",
                        snippet: "Test result for \(params.query)"
                    )
                ],
                query: params.query
            )
        }
        
        XCTAssertTrue(toolManager.isRegistered("web_search"))
    }
    
    func testBuiltInHangUpRegistration() {
        toolManager.registerHangUp { params in
            ToolManager.HangUpResult(
                success: true,
                message: "Hanging up: \(params.reason ?? "no reason")"
            )
        }
        
        XCTAssertTrue(toolManager.isRegistered("hang_up"))
    }
    
    // MARK: - Concurrency Tests
    
    func testConcurrentToolRegistration() async {
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<100 {
                group.addTask {
                    self.toolManager.register("tool_\(i)") { _ in
                        return "Result \(i)"
                    }
                }
            }
        }
        
        // All tools should be registered
        XCTAssertEqual(toolManager.registeredTools.count, 100)
    }
    
    func testMaxConcurrentExecutions() async {
        toolManager.configuration.maxConcurrentExecutions = 2
        
        var executionCount = 0
        let lock = NSLock()
        
        toolManager.register("counting_tool") { _ in
            lock.lock()
            executionCount += 1
            let current = executionCount
            lock.unlock()
            
            // Hold for a bit
            try await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
            
            return "Execution \(current)"
        }
        
        // Start 5 executions
        await withTaskGroup(of: ToolManager.ExecutionResult.self) { group in
            for i in 0..<5 {
                group.addTask {
                    let call = self.createMockToolCall(
                        name: "counting_tool",
                        parameters: "{}",
                        toolCallId: "call_\(i)"
                    )
                    return await self.toolManager.execute(call)
                }
            }
            
            // Collect results
            var results: [ToolManager.ExecutionResult] = []
            for await result in group {
                results.append(result)
            }
            
            // Should have limited concurrent executions
            // Some may have been cancelled due to max concurrent limit
            let successCount = results.filter {
                if case .success = $0 { return true }
                return false
            }.count
            
            XCTAssertLessThanOrEqual(successCount, toolManager.configuration.maxConcurrentExecutions)
        }
    }
    
    // MARK: - Helper Methods
    
    private func createMockToolCall(
        name: String,
        parameters: String,
        toolCallId: String = "test-id"
    ) -> ToolCallMessage {
        ToolCallMessage(
            customSessionId: nil,
            name: name,
            parameters: parameters,
            responseRequired: true,
            toolCallId: toolCallId,
            toolType: nil,
            type: "tool_call"
        )
    }
}

// MARK: - ToolManagerDelegate Tests

class MockToolManagerDelegate: ToolManagerDelegate {
    var willExecuteCalls: [ToolCallMessage] = []
    var didCompleteCalls: [(ToolCallMessage, ToolManager.ExecutionResult)] = []
    var didFailCalls: [(ToolCallMessage, Error)] = []
    var shouldProceed = true
    
    func toolManager(_ manager: ToolManager, willExecute call: ToolCallMessage) async -> Bool {
        willExecuteCalls.append(call)
        return shouldProceed
    }
    
    func toolManager(_ manager: ToolManager, didComplete call: ToolCallMessage, result: ToolManager.ExecutionResult) async {
        didCompleteCalls.append((call, result))
    }
    
    func toolManager(_ manager: ToolManager, didFailExecution call: ToolCallMessage, error: Error) async {
        didFailCalls.append((call, error))
    }
}

final class ToolManagerDelegateTests: XCTestCase {
    
    func testDelegateCallbacks() async {
        let toolManager = ToolManager()
        let delegate = MockToolManagerDelegate()
        toolManager.delegate = delegate
        
        toolManager.register("test") { _ in "success" }
        
        let call = ToolCallMessage(
            customSessionId: nil,
            name: "test",
            parameters: "{}",
            responseRequired: true,
            toolCallId: "123",
            toolType: nil,
            type: "tool_call"
        )
        
        _ = await toolManager.execute(call)
        
        XCTAssertEqual(delegate.willExecuteCalls.count, 1)
        XCTAssertEqual(delegate.didCompleteCalls.count, 1)
        XCTAssertEqual(delegate.didFailCalls.count, 0)
    }
    
    func testDelegateCanPreventExecution() async {
        let toolManager = ToolManager()
        let delegate = MockToolManagerDelegate()
        delegate.shouldProceed = false
        toolManager.delegate = delegate
        
        toolManager.register("test") { _ in
            XCTFail("Should not execute")
            return "failure"
        }
        
        let call = ToolCallMessage(
            customSessionId: nil,
            name: "test",
            parameters: "{}",
            responseRequired: true,
            toolCallId: "123",
            toolType: nil,
            type: "tool_call"
        )
        
        let result = await toolManager.execute(call)
        
        switch result {
        case .error(let message, let code):
            XCTAssertTrue(message.contains("cancelled"))
            XCTAssertEqual(code, "CANCELLED_BY_DELEGATE")
        default:
            XCTFail("Expected cancellation")
        }
    }
}