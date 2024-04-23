/// A loader protocol that represents an actual implementation of `ModifiedAtom`.
public struct ModifiedAtomLoader<Node: Atom, Modifier: AtomModifier>: AtomLoader where Node.Loader.Value == Modifier.BaseValue {
    /// A type of value to provide.
    public typealias Value = Modifier.Value

    /// A type to coordinate with the atom.
    public typealias Coordinator = Void

    private let atom: Node
    private let modifier: Modifier

    internal init(atom: Node, modifier: Modifier) {
        self.atom = atom
        self.modifier = modifier
    }

    /// Returns a new value for the corresponding atom.
    public func value(context: Context) -> Value {
        let value = context.transaction { $0.watch(atom) }
        return modifier.modify(value: value, context: context.modifierContext)
    }

    /// Manage given overridden value updates and cancellations.
    public func manageOverridden(value: Value, context: Context) -> Value {
        modifier.manageOverridden(value: value, context: context.modifierContext)
    }

    /// Returns a boolean value indicating whether it should notify updates downstream
    /// by checking the equivalence of the given old value and new value.
    public func shouldPropagateUpdate(newValue: Value, oldValue: Value) -> Bool {
        modifier.shouldPropagateUpdate(newValue: newValue, oldValue: oldValue)
    }

    /// Performs atom update.
    public func performPropagativeUpdate(_ body: () -> Void) {
        modifier.performPropagativeUpdate(body)
    }
}

extension ModifiedAtomLoader: RefreshableAtomLoader where Node.Loader: RefreshableAtomLoader, Modifier: RefreshableAtomModifier {
    /// Refreshes and waits until the asynchronous process is finished and returns a final value.
    public func refresh(context: Context) async -> Value {
        let value = await context.transaction { context in
            await context.refresh(atom)
            return context.watch(atom)
        }
        return await modifier.refresh(modifying: value, context: context.modifierContext)
    }

    /// Refreshes and waits for the passed value to finish outputting values
    /// and returns a final value.
    public func refresh(overridden value: Value, context: Context) async -> Value {
        await modifier.refresh(overridden: value, context: context.modifierContext)
    }
}
