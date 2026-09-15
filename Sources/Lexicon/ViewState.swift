import SwiftUI

/// Selects SwiftUI's public property wrapper instead of the SDK 27 State macro,
/// whose plugin is absent from Command Line Tools. SwiftUI still owns storage.
typealias ViewState<Value> = SwiftUI.State<Value>
