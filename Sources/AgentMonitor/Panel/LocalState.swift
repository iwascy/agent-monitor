import SwiftUI

/// Fallback property wrapper for `SwiftUI.State`.
///
/// In the Xcode Command Line Tools (CLT) environment without the full Xcode.app installed,
/// the Swift compiler attempts to expand the `@State` macro using `libSwiftUIMacros.dylib`,
/// which results in the compiler error:
/// `external macro implementation type 'SwiftUIMacros.StateMacro' could not be found`.
///
/// `LocalState` directly encapsulates `SwiftUI.State<Value>` and conforms to `DynamicProperty`,
/// providing identical SwiftUI state semantics and `$binding` projection without invoking the macro plugin.
@propertyWrapper
public struct LocalState<Value>: DynamicProperty {
    private var state: State<Value>

    public init(wrappedValue: Value) {
        self.state = State(initialValue: wrappedValue)
    }

    public var wrappedValue: Value {
        get { state.wrappedValue }
        nonmutating set { state.wrappedValue = newValue }
    }

    public var projectedValue: Binding<Value> {
        state.projectedValue
    }
}
