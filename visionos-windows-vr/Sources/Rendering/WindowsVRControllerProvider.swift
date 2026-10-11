import ARKit
import CoreHaptics
import GameController
import QuartzCore
import simd

/// visionOS accessory tracking and GameController input adapter for the native
/// OpenVR/OpenXR-facing ABI. This only reports sensors/actions; it does not
/// invent poses or mark absent controllers as tracked.
@available(visionOS 26.0, *)
final class WindowsVRControllerProvider: @unchecked Sendable {
    private let lock = NSLock()
    private var accessoryProvider: AccessoryTrackingProvider?
    private var anchorsByRole: [UInt32: AccessoryAnchor] = [:]
    private var controllersByRole: [UInt32: GCController] = [:]
    private var hapticEnginesByRole: [UInt32: CHHapticEngine] = [:]
    private var anchorUpdatesTask: Task<Void, Never>?
    private var trackingGeneration: UInt64 = 0

    func configure(authorized: Bool) async -> [any DataProvider] {
        guard authorized, AccessoryTrackingProvider.isSupported else {
            reset()
            return []
        }

        let generation = lock.withLock {
            trackingGeneration &+= 1
            return trackingGeneration
        }

        var accessories: [Accessory] = []
        for controller in GCController.controllers()
        where controller.productCategory == GCProductCategorySpatialController {
            do {
                let accessory = try await Accessory(device: controller)
                guard let role = Self.role(for: accessory.inherentChirality) else { continue }
                store(controller, for: role)
                accessories.append(accessory)
            } catch {
                // Keep the app available if a paired controller disconnects
                // during Accessory creation; the ABI continues to report it
                // as unavailable instead of fabricating a pose.
            }
        }

        guard !accessories.isEmpty else {
            publishUnavailable(role: 0)
            publishUnavailable(role: 1)
            return []
        }

        let provider = AccessoryTrackingProvider(accessories: accessories)
        store(provider)
        anchorUpdatesTask = Task { [weak self, provider, generation] in
            for await update in provider.anchorUpdates {
                guard let self, self.isCurrentTrackingGeneration(generation) else { return }
                switch update.event {
                case .added, .updated:
                    guard let role = Self.role(for: update.anchor.accessory.inherentChirality) else { continue }
                    self.store(update.anchor, for: role, generation: generation)
                case .removed:
                    guard let role = Self.role(for: update.anchor.accessory.inherentChirality) else { continue }
                    self.removeAnchor(for: role, generation: generation)
                    self.publishUnavailable(role: role)
                @unknown default:
                    continue
                }
            }
        }
        return [provider]
    }

    /// Clears all cached device samples and stops controller haptics when the
    /// compositor is paused or invalidated. Fresh anchor updates repopulate the
    /// cache after tracking is restarted.
    func reset() {
        let (updatesTask, engines) = lock.withLock {
            let task = anchorUpdatesTask
            anchorUpdatesTask = nil
            trackingGeneration &+= 1
            let engines = Array(hapticEnginesByRole.values)
            hapticEnginesByRole.removeAll()
            anchorsByRole.removeAll()
            controllersByRole.removeAll()
            accessoryProvider = nil
            return (task, engines)
        }
        updatesTask?.cancel()
        engines.forEach { $0.stop() }
        publishUnavailableState()
    }

    func publishUnavailableState() {
        publishUnavailable(role: 0)
        publishUnavailable(role: 1)
    }

    /// Called once for each compositor frame using its predicted ARKit time.
    /// Input snapshots are latest-state samples; the ABI does not queue stale
    /// controller input behind video frames.
    func publishPredictedState(at timestamp: TimeInterval) {
        for role: UInt32 in 0...1 {
            publishState(role: role, timestamp: timestamp)
            drainHaptic(role: role)
        }
    }

    private func publishState(role: UInt32, timestamp: TimeInterval) {
        let (provider, anchor, controller) = lock.withLock {
            (accessoryProvider, anchorsByRole[role], controllersByRole[role])
        }

        let predictedAnchor: AccessoryAnchor?
        if let provider, let anchor {
            predictedAnchor = provider.predictAnchor(for: anchor, at: timestamp)
        } else {
            predictedAnchor = nil
        }

        var buttons: UInt64 = 0
        var trigger: Float = 0
        var grip: Float = 0
        var stickX: Float = 0
        var stickY: Float = 0
        if let controller {
            controller.input.inputStateQueueDepth = 1
            if let snapshot = controller.input.nextInputState() {
                let inputButtons = snapshot.buttons
                let inputAxes = snapshot.axes
                let inputDpads = snapshot.dpads
                if pressed({ inputButtons[$0]?.pressedInput.isPressed == true }, ["Primary Button", "Button A", "Button X"]) { buttons |= 1 << 0 }
                if pressed({ inputButtons[$0]?.pressedInput.isPressed == true }, ["Secondary Button", "Button B", "Button Y"]) { buttons |= 1 << 1 }
                if pressed({ inputButtons[$0]?.pressedInput.isPressed == true }, ["Button Menu", "Button Options", "Button Home"]) { buttons |= 1 << 2 }
                if pressed({ inputButtons[$0]?.pressedInput.isPressed == true }, ["Thumbstick Button", "Right Thumbstick Button"]) { buttons |= 1 << 3 }
                if pressed({ inputButtons[$0]?.pressedInput.isPressed == true }, ["Trigger", "Right Trigger"]) { buttons |= 1 << 4 }
                if pressed({ inputButtons[$0]?.pressedInput.isPressed == true }, ["Grip", "Tip", "Right Shoulder"]) { buttons |= 1 << 5 }
                if pressed({ inputButtons[$0]?.touchedInput?.isTouched == true }, ["Trigger", "Right Trigger"]) { buttons |= 1 << 6 }
                if pressed({ inputButtons[$0]?.touchedInput?.isTouched == true }, ["Grip", "Tip", "Right Shoulder"]) { buttons |= 1 << 7 }

                trigger = scalar({ inputButtons[$0]?.pressedInput.value }, ["Trigger", "Right Trigger"])
                grip = scalar({ inputButtons[$0]?.pressedInput.value }, ["Grip", "Tip", "Right Shoulder"])
                if let stick = inputDpads["Thumbstick"] {
                    stickX = stick.xAxis.value
                    stickY = stick.yAxis.value
                } else {
                    stickX = scalar({ inputAxes[$0]?.absoluteInput?.value }, ["Thumbstick X Axis", "Left Thumbstick X Axis", "Right Thumbstick X Axis"])
                    stickY = scalar({ inputAxes[$0]?.absoluteInput?.value }, ["Thumbstick Y Axis", "Left Thumbstick Y Axis", "Right Thumbstick Y Axis"])
                }
            }
        }

        let tracked = predictedAnchor?.isTracked == true
        let matrix = tracked
            ? matrixValues(predictedAnchor!.originFromAnchorTransform)
            : matrixValues(matrix_identity_float4x4)
        let flags: UInt32 = (tracked ? 0b011 : 0) | (controller == nil ? 0 : 0b100)
        matrix.withUnsafeBufferPointer { buffer in
            _ = wvr_compositor_publish_controller_state_v1(
                role, flags, UInt64(max(0, timestamp * 1.0e9)), buffer.baseAddress,
                buttons, trigger, grip, stickX, stickY
            )
        }
    }

    private func drainHaptic(role: UInt32) {
        var request = WVRHapticRequestV1()
        request.structSize = UInt32(MemoryLayout<WVRHapticRequestV1>.size)
        guard wvr_compositor_take_haptic_v1(role, &request) == 0,
              request.amplitude > 0,
              request.durationSeconds > 0
        else { return }

        let (controller, existingEngine) = lock.withLock {
            (controllersByRole[role], hapticEnginesByRole[role])
        }
        var engine = existingEngine
        guard let haptics = controller?.haptics else { return }

        if engine == nil {
            let locality = role == 0 ? GCHapticsLocality.leftHandle : GCHapticsLocality.rightHandle
            engine = haptics.createEngine(withLocality: locality) ?? haptics.createEngine(withLocality: GCHapticsLocality.all)
            do { try engine?.start() } catch { engine = nil }
            lock.withLock { hapticEnginesByRole[role] = engine }
        }
        guard let engine else { return }

        do {
            let pattern = try CHHapticPattern(events: [
                CHHapticEvent(eventType: .hapticContinuous, parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: request.amplitude),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: min(1, request.frequencyHz / 1000))
                ], relativeTime: 0, duration: Double(request.durationSeconds))
            ], parameters: [])
            try engine.makePlayer(with: pattern).start(atTime: engine.currentTime)
        } catch {
            engine.stop()
            lock.withLock { hapticEnginesByRole[role] = nil }
        }
    }

    private func publishUnavailable(role: UInt32) {
        let identity = matrixValues(matrix_identity_float4x4)
        identity.withUnsafeBufferPointer { buffer in
            _ = wvr_compositor_publish_controller_state_v1(role, 0, 0, buffer.baseAddress, 0, 0, 0, 0, 0)
        }
    }

    private func store(_ controller: GCController, for role: UInt32) {
        lock.withLock { controllersByRole[role] = controller }
    }

    private func store(_ provider: AccessoryTrackingProvider) {
        lock.withLock { accessoryProvider = provider }
    }

    private func store(_ anchor: AccessoryAnchor, for role: UInt32, generation: UInt64) {
        lock.withLock {
            guard trackingGeneration == generation else { return }
            anchorsByRole[role] = anchor
        }
    }

    private func removeAnchor(for role: UInt32, generation: UInt64) {
        let engine: CHHapticEngine? = lock.withLock {
            guard trackingGeneration == generation else { return nil }
            anchorsByRole.removeValue(forKey: role)
            controllersByRole.removeValue(forKey: role)
            return hapticEnginesByRole.removeValue(forKey: role)
        }
        engine?.stop()
    }

    private func isCurrentTrackingGeneration(_ generation: UInt64) -> Bool {
        lock.withLock { trackingGeneration == generation }
    }

    private static func role(for chirality: Accessory.Chirality) -> UInt32? {
        switch chirality {
        case .left: 0
        case .right: 1
        default: nil
        }
    }

    private func pressed(_ read: (String) -> Bool, _ names: [String]) -> Bool {
        names.contains(where: read)
    }

    private func scalar(_ read: (String) -> Float?, _ names: [String]) -> Float {
        names.lazy.compactMap(read).first ?? 0
    }

    private func matrixValues(_ matrix: simd_float4x4) -> [Float] {
        [
            matrix.columns.0.x, matrix.columns.0.y, matrix.columns.0.z, matrix.columns.0.w,
            matrix.columns.1.x, matrix.columns.1.y, matrix.columns.1.z, matrix.columns.1.w,
            matrix.columns.2.x, matrix.columns.2.y, matrix.columns.2.z, matrix.columns.2.w,
            matrix.columns.3.x, matrix.columns.3.y, matrix.columns.3.z, matrix.columns.3.w
        ]
    }

    deinit {
        anchorUpdatesTask?.cancel()
        hapticEnginesByRole.values.forEach { $0.stop() }
    }
}
