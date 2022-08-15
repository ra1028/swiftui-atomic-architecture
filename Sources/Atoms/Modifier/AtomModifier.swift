public extension Atom {
    /// Applies a modifier to an atom and returns a new atom.
    ///
    /// - Parameter modifier: The modifier to apply to this atom.
    /// - Returns: A new atom that is applied the given modifier.
    func modifier<T: AtomModifier>(_ modifier: T) -> ModifiedAtom<Self, T> {
        ModifiedAtom(atom: self, modifier: modifier)
    }
}

/// A modifier that you apply to an atom, producing a  different version
/// of the original value.
public protocol AtomModifier {
    /// A type representing the stable identity of this modifier.
    associatedtype Key: Hashable

    /// A type of original value to be modified.
    associatedtype Value

    /// A type of modified value to provide.
    associatedtype ModifiedValue

    /// A type of the context structure that to interact with an atom store.
    typealias Context = AtomLoaderContext<ModifiedValue>

    /// A unique value used to identify the modifier internally.
    var key: Key { get }

    /// Returns a boolean value that determines whether it should notify the value update to
    /// watchers with comparing the given old value and the new value.
    ///
    /// - Parameters:
    ///   - newValue: The new value after update.
    ///   - oldValue: The old value before update.
    ///
    /// - Returns: A boolean value that determines whether it should notify the value update
    ///            to watchers.
    @MainActor
    func shouldNotifyUpdate(newValue: ModifiedValue, oldValue: ModifiedValue) -> Bool

    /// Returns a value with initiating the update process and caches the value for
    /// the next access.
    ///
    /// - Parameters:
    ///   - context: The context structure that to interact with an atom store.
    ///   - value: The original value to be modified.
    ///   - setValue: The closure that to set a new value to the original atom's state.
    ///
    /// - Returns: A modified value.
    @MainActor
    func value(context: Context, with value: Value) -> ModifiedValue

    @MainActor
    func handle(context: Context, with value: ModifiedValue) -> ModifiedValue
}

public extension AtomModifier {
    func shouldNotifyUpdate(newValue: ModifiedValue, oldValue: ModifiedValue) -> Bool {
        true
    }
}
