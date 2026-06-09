import AppKit
import SwiftUI

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// .regular が必要:
//   - アクセサリ (.accessory / LSUIElement=true) だと NSPanel 内の TextField で
//     TSM/IMK の通信エラーが起きてクラッシュする (macOS 26 で確認)
//   - Dock アイコン出るが floating window の挙動には影響しない
app.setActivationPolicy(.regular)
app.run()
