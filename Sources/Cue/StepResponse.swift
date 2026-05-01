import Foundation
import CoreGraphics

struct StepResponse {
    enum ActionType {
        case click(x: CGFloat, y: CGFloat, elementType: ElementType, width: CGFloat, height: CGFloat)
        case rightClick(x: CGFloat, y: CGFloat, elementType: ElementType, width: CGFloat, height: CGFloat)
        case scroll(x: CGFloat, y: CGFloat, direction: ScrollDirection, amount: Int)
        case type(x: CGFloat, y: CGFloat, text: String)
        case key(keys: String)
        case navigate(url: String)
        case openTabAndNavigate(url: String)
        case shell(command: String)
        case none
    }

    enum ElementType: String {
        case button, link, text, field, icon, other
    }

    enum ScrollDirection: String {
        case up, down, left, right
    }

    let instruction: String
    let action: ActionType
    let isComplete: Bool
    var targetDescription: String = ""
    var requiresUserInput: Bool = false
}
