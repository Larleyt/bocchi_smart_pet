import BocchiCore
import Foundation

enum PetInteractionEvent: Equatable {
    case clicked
    case dragBegan
    case dragChanged(PetRect)
    case dragEnded(PetRect)
    case hoverEscapeRequested(PetRect)
    case movementEnded(PetRect)
}

struct PetInteractionState {
    static let escapeDelay = 5.0

    private var hoveredAt: Double?
    private var pressed = false
    private var escapeSent = false

    mutating func hoverChanged(isOverPet: Bool, now: Double) {
        guard !pressed else { return }
        if isOverPet {
            if hoveredAt == nil {
                hoveredAt = now
                escapeSent = false
            }
        } else {
            hoveredAt = nil
            escapeSent = false
        }
    }

    mutating func mouseDown() {
        pressed = true
        hoveredAt = nil
        escapeSent = false
    }

    mutating func mouseUp(isOverPet: Bool, now: Double) {
        pressed = false
        hoveredAt = isOverPet ? now : nil
        escapeSent = false
    }

    mutating func reset() {
        hoveredAt = nil
        pressed = false
        escapeSent = false
    }

    mutating func escapeIsDue(now: Double) -> Bool {
        guard !pressed, !escapeSent, let hoveredAt,
              now - hoveredAt >= Self.escapeDelay else { return false }
        escapeSent = true
        return true
    }
}

enum PetMotion {
    static func placement(from: PetRect, to: PetRect, progress: Double) -> PetRect {
        let clamped = min(1, max(0, progress))
        let eased = clamped * clamped * (3 - 2 * clamped)
        return PetRect(x: from.x + (to.x - from.x) * eased,
                       y: from.y + (to.y - from.y) * eased,
                       width: to.width, height: to.height)
    }
}
