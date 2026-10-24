import SwiftUI

/// En el SDK de macOS 27 `@State` es una macro cuyo plugin (SwiftUIMacros) solo
/// se distribuye con Xcode. Este alias apunta al property wrapper clásico, así el
/// proyecto compila también con las Command Line Tools.
typealias ViewState<Value> = SwiftUI.State<Value>
