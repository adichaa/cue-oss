import Foundation

@MainActor
final class ApprovalManager {
    private let highStakeKeywords = [
        "delete", "remove", "send", "submit", "buy", "purchase", "confirm",
        "sign out", "log out", "logout", "uninstall", "format", "erase", "trash",
        "pay", "checkout", "place order", "deactivate", "terminate", "cancel account",
        "password", "secret", "token", "credential", "ssn", "card number",
        "add to cart", "buy now", "proceed to checkout", "place your order",
    ]
    private let highStakeKeyCombos: Set<String> = [
        "cmd+q", "command+q", "cmd+w", "command+w",
        "cmd+delete", "command+delete", "cmd+backspace", "command+backspace",
    ]

    /// True if the action is high-stakes and must always prompt regardless of policy.
    func isHighStake(action: StepResponse.ActionType, targetDescription: String, instruction: String = "") -> Bool {
        let combined = (targetDescription + " " + instruction).lowercased()
        switch action {
        case .key(let keys):
            return highStakeKeyCombos.contains(keys.lowercased())
        case .click, .rightClick, .type:
            return highStakeKeywords.contains(where: { combined.contains($0) })
        case .scroll, .navigate, .openTabAndNavigate, .shell, .none:
            return false
        }
    }

    func reset() {}
}
