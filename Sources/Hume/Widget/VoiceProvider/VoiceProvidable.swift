//
//  VoiceProvidable.swift
//  Hume
//
//  Created by Chris on 6/12/25.
//

import Combine
import Foundation

public protocol VoiceProvidable {
  var state: AnyPublisher<VoiceProviderState, Never> { get }
  var delegate: VoiceProviderDelegate? { get set }
  var isOutputMeteringEnabled: Bool { get set }
  var microphoneMode: MicrophoneMode { get }
  
  /// The tool manager for registering and configuring tool handlers
  var tools: ToolManager { get }

  /// Connects the VoiceProvider to the backend and prepares audio streaming.
  /// - Throws: `VoiceProviderError` for connection, configuration, or audio errors.
  @MainActor func connect(
    configId: String?, configVersion: String?, resumedChatGroupId: String?,
    sessionSettings: SessionSettings) async throws
  /// Disconnects the VoiceProvider and stops audio streaming.
  @MainActor func disconnect() async

  /// Mutes or unmutes the microphone.
  /// - Parameter mute: Pass `true` to mute, `false` to unmute.
  func mute(_ mute: Bool)

  // MARK: - Tool Response Methods
  
  /// Sends a tool response to EVI. Use this for manual tool handling.
  func sendToolResponse(_ response: ToolResponseMessage) async throws

  /// Sends a tool error to EVI. Use this for manual tool handling.
  func sendToolError(_ error: ToolErrorMessage) async throws
}
