import SwiftUI
import UIKit

enum AdaptiveLayout {
    static func isPadLandscape(_ size: CGSize) -> Bool {
        UIDevice.current.userInterfaceIdiom == .pad && size.width > size.height
    }
}
