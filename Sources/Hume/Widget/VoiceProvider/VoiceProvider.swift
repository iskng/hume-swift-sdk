import AVFoundation
import Combine
import Foundation

public class VoiceProvider: VoiceProvidable {
  public var state: AnyPublisher<VoiceProviderState, Never> {
    stateSubject.eraseToAnyPublisher()
  }
  private let stateSubject = CurrentValueSubject<VoiceProviderState, Never>(.disconnected)

  private let humeClient: HumeClient
  private var socket: StreamSocket?
  private let delegateQueue = DispatchQueue(
    label: "\(Constants.Namespace).delegate.queue", qos: .userInteractive)
  private var eventSubscription: Task<(), any Error>?

  private var audioHub: AudioHub = AudioHubImpl()
  private var audioHubStateCancellable: AnyCancellable?

  private var connectionContinuation: CheckedContinuation<(), any Error>?

  public weak var delegate: (any VoiceProviderDelegate)?

  // MARK: - Tool Management
  public let tools: ToolManager
  private var toolExecutionTask: Task<Void, Never>?

  // MARK: - Metering
  public var isOutputMeteringEnabled: Bool = false {
    didSet {
      audioHub.isOutputMeteringEnabled = isOutputMeteringEnabled
    }
  }

  // MARK: - Microphone

  public var microphoneMode: MicrophoneMode {
    return audioHub.microphoneMode
  }

  // MARK: Init/deinit

  public init(client: HumeClient, toolConfiguration: ToolManager.Configuration = .init()) {
    self.humeClient = client
    self.tools = ToolManager(configuration: toolConfiguration)
    
    // Set up internal tool manager delegate
    self.tools.delegate = self
  }

  deinit {
    eventSubscription?.cancel()
    toolExecutionTask?.cancel()
    tools.cancelAllExecutions()
  }

  // MARK: - Connection

  /// Starts a connection with EVI.
  /// - Parameters:
  ///   - configId: The unique identifier for an EVI configuration.
  ///   - configVersion: Include this parameter to apply a specific version of an EVI configuration. If omitted, the latest version will be applied.
  ///   - resumedChatGroupId: The unique identifier for a Chat Group. Use this field to preserve context from a previous Chat session.
  ///   - sessionSettings: Defines the session settings for the connection. Setting the `audio` configuration to `nil` will enable `VoiceProvider` to configure this automatically.
  public func connect(
    configId: String?, configVersion: String?, resumedChatGroupId: String?,
    sessionSettings: SessionSettings
  ) async throws {
    Logger.info(
      "Connecting voice provider. configId: \(String(describing: configId)), configVersion: \(String(describing: configVersion)), resumedChatGroupId: \(String(describing: resumedChatGroupId))"
    )
    if stateSubject.value == .disconnecting {
      // need to wait to finish disconnecting
      Logger.debug("was in the middle of disconnecting, waiting to finish...")
      try await stateSubject.waitFor(.disconnected)
      Logger.debug("...disconnected")
    }
    stateSubject.send(.connecting)
    audioHub.microphoneDataChunkHandler = handleMicrophoneData(_:averagePower:)
    if audioHub.stateSubject.value == .unconfigured {
      try await audioHub.configure(with: .voiceChat)
    }

    var defaultedSessionSettings: SessionSettings? = nil
    if sessionSettings.audio == nil {
      defaultedSessionSettings = sessionSettings.copy(
        audio: AudioConfiguration(
          channels: 1,
          encoding: .linear16,
          sampleRate: Int(Constants.SampleRate))
      )
    }

    try await withCheckedThrowingContinuation { [defaultedSessionSettings] continuation in
      // open socket
      Task {
        self.socket = try? await self.humeClient.empathicVoice.chat
          .connect(
            configId: configId,
            configVersion: configVersion,
            resumedChatGroupId: resumedChatGroupId,
            onOpen: { [weak self] response in
              Logger.info("Socket Opened")
              guard let self = self else { return }
              Task {
                do {
                  Logger.info("Voice provider listening for events")
                  self.startListeningForEvents()
                  try await self.sendSessionSettings(
                    message: defaultedSessionSettings ?? sessionSettings)

                  Logger.info("Waiting to receive chat metadata to finalize AudioHub")
                  self.connectionContinuation = continuation
                } catch {
                  self.stateSubject.send(.disconnected)
                  continuation.resume(throwing: error)
                }
              }
            },
            onClose: { [weak self] closeCode, reason in
              Logger.warn("Socket Closed: \(closeCode). Reason: \(String(describing: reason))")
              if self?.stateSubject.value == .connected || self?.stateSubject.value == .connecting {
                Task { await self?.disconnect() }
              }
            },
            onError: { error, response in
              Logger.warn("Socket Errored: \(error). Response: \(String(describing: response))")
            }
          )
      }
    }
  }

  private func completeConnectionSetup(error: Error? = nil) {
    guard let connectionContinuation else {
      Logger.error("missing connection continuation")
      Task { await self.disconnect() }
      return
    }

    if let error {
      Task {
        await self.disconnect()
        connectionContinuation.resume(throwing: error)
      }
    } else {
      Logger.info("Finalizing audio hub configuration")
      self.audioHub.isOutputMeteringEnabled = self.isOutputMeteringEnabled
      self.audioHub.outputMeterListener = self.handleOutputMeter(_:)
      self.stateSubject.send(.connected)
      self.delegateQueue.async {
        self.delegate?.voiceProviderDidConnect(self)
      }
      connectionContinuation.resume()
      Logger.info("Voice Provider connected successfully")
    }
    self.connectionContinuation = nil
  }

  public func disconnect() async {
    Logger.info("attempting to disconnect voice provider")
    guard [.connected, .connecting].contains(stateSubject.value) else {
      Logger.info("not connected")
      return
    }
    await MainActor.run { stateSubject.send(.disconnecting) }
    self.delegateQueue.async {
      self.delegate?.voiceProviderWillDisconnect(self)
    }
    Logger.info("Disconnecting voice provider")

    // Cancel any ongoing tool executions
    toolExecutionTask?.cancel()
    tools.cancelAllExecutions()
    
    do {
      try await self.audioHub.stop()
    } catch {
      Logger.error("Failed to stop audio hub: \(error)")
    }
    self.eventSubscription?.cancel()
    self.socket?.close()
    Logger.info("Voice provider disconnected")
    self.delegateQueue.async {
      self.delegate?.voiceProviderDidDisconnect(self)
    }
    stateSubject.send(.disconnected)
  }

  // MARK: - Controls
  public func mute(_ mute: Bool) {
    audioHub.muteMic(mute)
  }

  public func sendUserInput(message: String) async throws {
    try await socket?.sendTextInput(text: message)
  }

  public func sendAssistantInput(message: String) async throws {
    try await socket?.sendAssistantInput(message: AssistantInput(text: message))
  }

  public func sendSessionSettings(message: SessionSettings) async throws {
    try await socket?.sendSessionSettings(message: message)
  }

  public func sendPauseAssistantMessage(message: PauseAssistantMessage) async throws {
    try await socket?.pauseAssistant(message: message)

  }

  public func sendResumeAssistantMessage(message: ResumeAssistantMessage) async throws {
    try await socket?.resumeAssistant(message: message)
  }

  // MARK: - Tool Response Methods (for manual handling)
  
  /// Sends a tool response message directly to EVI.
  /// Use this when you want to handle tool execution manually instead of using the ToolManager.
  public func sendToolResponse(_ response: ToolResponseMessage) async throws {
    try await socket?.sendToolResponse(message: response)
  }

  /// Sends a tool error message directly to EVI.
  /// Use this when you want to handle tool execution manually instead of using the ToolManager.
  public func sendToolError(_ error: ToolErrorMessage) async throws {
    try await socket?.sendToolError(message: error)
  }
}

// MARK: - Private
extension VoiceProvider {
  // MARK: Event handling
  private func startListeningForEvents() {
    Logger.info("Starting to listen for events")

    // Wrap listening logic in an async block for better control
    eventSubscription = Task.detached(priority: .high) {
      try await withThrowingTaskGroup(of: Void.self) { group in
        guard let socket = self.socket else {
          throw VoiceProviderError.socketDisconnected
        }

        group.addTask { [weak self] in
          guard let self else {
            Logger.warn("lost self")
            return
          }

          do {
            Logger.info("Waiting for events on socket")
            for try await event in socket.receive() {
              try self.handleIncomingEvent(event)
            }
          } catch let error as StreamSocketError {
            switch error {
            case .connectionError, .transportError:
              Logger.error("Error receiving messages: \(error). Disconnecting...")
              Task { await self.disconnect() }
            case .closed, .disconnected:
              Logger.debug("Event subscription received \(error.rawValue) code.")
            case .encodingError, .decodingError:
              Logger.warn("Event subscription received \(error.rawValue) code")
            }
          } catch {
            Logger.error("Unknown error receiving messages: \(error). Disconnecting...")
            Task { await self.disconnect() }
          }
        }
      }
    }
  }

  /// Handles individual incoming events
  private func handleIncomingEvent(_ event: SubscribeEvent) throws {
    switch event {
    case .audioOutput(let audioOutput):
      guard let clip = SoundClip.from(audioOutput) else {
        Logger.error("Failed to decode audio output")
        return
      }
      Task {
        do {
          try await self.audioHub.enqueue(soundClip: clip)
          self.delegateQueue.async {
            self.delegate?.voiceProvider(self, didPlayClip: clip)
          }
        } catch let error as AudioHubError {
          Logger.warn("Failed to enqueue audio output: \(error)")
          self.delegateQueue.async {
            self.delegate?.voiceProvider(self, didProduceError: .audioHubError(error))
          }
        } catch {
          Logger.error("Unknown error while trying to enqueue audio output: \(error)")
          self.delegateQueue.async {
            self.delegate?.voiceProvider(self, didProduceError: .unknown(error))
          }
        }
      }
    case .userInterruption:
      self.audioHub.handleInterruption()
    case .chatMetadata(let response):
      Logger.debug(
        """
        --Received metadata response--
        Chat ID: \(response.chatId)
        Chat Group ID: \(response.chatGroupId)
        """)
      Task {
        do {
          try await self.audioHub.start()
          completeConnectionSetup()
        } catch {
          completeConnectionSetup(error: error)
        }
      }
    case .webSocketError(let error):
      if error.slug == "inactivity_timeout" {
        Logger.warn("WebSocket error: \(error)")
      } else {
        Logger.error("WebSocket error: \(error)")
      }

      delegate?.voiceProvider(self, didProduceError: VoiceProviderError.websocketError(error))
      Task { await self.disconnect() }
    case .toolCallMessage(let call):
      handleToolCallMessage(call)
    case .toolResponseMessage, .toolErrorMessage:
      // These are responses from our tool execution, no action needed
      break
    default: break
    }
    self.delegate?.voiceProvider(self, didProduceEvent: event)
  }

  // MARK: Handlers
  private func handleOutputMeter(_ meter: Float) {
    self.delegateQueue.async {
      self.delegate?.voiceProvider(self, didReceieveAudioOutputMeter: meter)
    }
  }

  private func handleMicrophoneData(_ data: Data, averagePower: Float) async {
    guard stateSubject.value == .connected else {
      Logger.warn("handleMicData called without being connected")
      return
    }
    do {
      delegateQueue.async {
        self.delegate?.voiceProvider(self, didReceieveAudioInputMeter: averagePower)
      }
      try await self.socket?.sendData(message: data)
    } catch let error as StreamSocketError {
      // disconnect VoiceProvider if needed
      switch error {
      case .closed, .disconnected:
        Logger.warn("received closed or disconnected error while sending mic data, cleaning up")
        // if the socket is closed or disconnected while we're attempting to send mic data, it means AudioHub didn't
        try? await self.audioHub.stop()
      case .connectionError, .transportError, .encodingError, .decodingError:
        Logger.error("error sending mic data: \(error.rawValue), disconnecting...")
        delegateQueue.async {
          self.delegate?.voiceProvider(
            self, didProduceError: VoiceProviderError.socketSendError(error))
        }
        await self.disconnect()
      }
    } catch {
      Logger.error("error sending mic data: \(error)")
      delegateQueue.async {
        self.delegate?.voiceProvider(
          self, didProduceError: VoiceProviderError.socketSendError(error))
      }
    }
  }
}

// MARK: - Tool Handling
extension VoiceProvider {
  private func handleToolCallMessage(_ call: ToolCallMessage) {
    // First check with delegate if we should handle this tool
    let shouldExecute = delegate?.voiceProvider(self, shouldExecuteTool: call) ?? true
    
    guard shouldExecute else {
      Logger.info("Tool execution prevented by delegate for: \(call.name)")
      return
    }
    
    // Only auto-execute if configured and response is required
    guard tools.configuration.autoExecute && call.responseRequired else {
      Logger.info("Manual tool handling required for: \(call.name)")
      return
    }
    
    // Cancel any existing execution task
    toolExecutionTask?.cancel()
    
    // Create new execution task
    toolExecutionTask = Task { [weak self] in
      guard let self else { return }
      
      // Notify delegate
      self.delegateQueue.async {
        self.delegate?.voiceProvider(self, willExecuteTool: call)
      }
      
      // Execute the tool
      let result = await self.tools.execute(call)
      
      // Send response based on result
      do {
        switch result {
        case .success(let content):
          let response = ToolResponseMessage(
            content: content,
            customSessionId: call.customSessionId,
            toolCallId: call.toolCallId,
            toolName: call.name,
            toolType: call.toolType
          )
          try await self.socket?.sendToolResponse(message: response)
          
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
          try await self.socket?.sendToolError(message: error)
          
        case .timeout:
          let error = ToolErrorMessage(
            code: "TIMEOUT",
            content: nil,
            customSessionId: call.customSessionId,
            error: "Tool execution timed out",
            level: .warn,
            toolCallId: call.toolCallId,
            toolType: call.toolType
          )
          try await self.socket?.sendToolError(message: error)
          
        case .cancelled:
          Logger.info("Tool execution cancelled for: \(call.name)")
          // Don't send error for cancelled operations
        }
        
        // Notify delegate of completion
        self.delegateQueue.async {
          self.delegate?.voiceProvider(self, didExecuteTool: call, result: result)
        }
        
      } catch {
        Logger.error("Failed to send tool response: \(error)")
        self.delegateQueue.async {
          self.delegate?.voiceProvider(self, didFailToolExecution: call, error: error)
        }
      }
    }
  }
}

// MARK: - ToolManagerDelegate
extension VoiceProvider: ToolManagerDelegate {
  public func toolManager(_ manager: ToolManager, willExecute call: ToolCallMessage) async -> Bool {
    // Additional validation could go here
    return true
  }
  
  public func toolManager(_ manager: ToolManager, didComplete call: ToolCallMessage, result: ToolManager.ExecutionResult) async {
    Logger.info("Tool execution completed: \(call.name)")
  }
  
  public func toolManager(_ manager: ToolManager, didFailExecution call: ToolCallMessage, error: Error) async {
    Logger.error("Tool execution failed for \(call.name): \(error)")
  }
}
