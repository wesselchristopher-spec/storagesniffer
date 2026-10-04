import SwiftUI

/// SwiftUI's `@State` is a compiler macro in recent SDKs, and its plugin ships only with Xcode.
/// This alias names the underlying property wrapper directly so the app also builds with
/// just the Command Line Tools. It behaves exactly like `@State`.
typealias ViewState<Value> = SwiftUI.State<Value>
