import Foundation

@usableFromInline
@MainActor
internal struct RootAtomStore {
    private weak var store: Store?
    private let overrides: Overrides?
    private let observers: [AtomObserver]

    init(
        store: Store,
        overrides: Overrides? = nil,
        observers: [AtomObserver] = []
    ) {
        self.store = store
        self.overrides = overrides
        self.observers = observers
    }
}

extension RootAtomStore: AtomStore {
    @usableFromInline
    func read<Node: Atom>(_ atom: Node) -> Node.Loader.Value {
        getValue(for: atom)
    }

    @usableFromInline
    func set<Node: StateAtom>(_ value: Node.Value, for atom: Node) {
        // Do nothing if the atom is not yet to be watched.
        guard let oldValue = getCachedState(for: atom)?.value else {
            return
        }

        let context = prepareTransaction(for: atom)

        context.transaction { context in
            atom.willSet(newValue: value, oldValue: oldValue, context: context)
            update(atom: atom, with: value)
            atom.didSet(newValue: value, oldValue: oldValue, context: context)
        }
    }

    @usableFromInline
    func watch<Node: Atom>(
        _ atom: Node,
        container: SubscriptionContainer.Wrapper,
        notifyUpdate: @escaping () -> Void
    ) -> Node.Loader.Value {
        guard let store = store else {
            return getNewValue(for: atom)
        }

        let key = AtomKey(atom)
        let subscriptionKey = container.key
        let subscription = Subscription(notifyUpdate: notifyUpdate) { [weak store] in
            guard let store = store else {
                return
            }

            // Remove subscription from the store.
            store.state.subscriptions[key]?.removeValue(forKey: subscriptionKey)
            // Release the atom if it is no longer watched to.
            checkRelease(for: key)
        }

        registerIfAbsent(atom: atom)

        // Assign subscription to the container so the caller side can unsubscribe.
        container.insert(subscription: subscription, for: key)

        // Assign subscription to the store.
        store.state.subscriptions[key, default: [:]].updateValue(subscription, forKey: subscriptionKey)

        return getValue(for: atom)
    }

    @usableFromInline
    func refresh<Node: Atom>(_ atom: Node) async -> Node.Loader.Value where Node.Loader: RefreshableAtomLoader {
        let context = prepareTransaction(for: atom)
        let value: Node.Loader.Value

        if let overrideValue = overrides?.value(for: atom) {
            value = await atom._loader.refresh(context: context, with: overrideValue)
        }
        else {
            value = await atom._loader.refresh(context: context)
        }

        update(atom: atom, with: value)
        return value
    }

    @usableFromInline
    func reset<Node: Atom>(_ atom: Node) {
        let value = getNewValue(for: atom)
        update(atom: atom, with: value)
    }

    @usableFromInline
    func relay(observers: [AtomObserver]) -> AtomStore {
        Self(
            store: store,
            overrides: overrides,
            observers: self.observers + observers
        )
    }
}

internal extension RootAtomStore {
    @usableFromInline
    func watch<Node: Atom>(_ atom: Node, in transaction: Transaction) -> Node.Loader.Value {
        guard !transaction.isTerminated, let store = store else {
            return getNewValue(for: atom)
        }

        let dependencyKey = AtomKey(atom)

        registerIfAbsent(atom: atom)

        store.graph.addEdge(for: dependencyKey, to: transaction.key)

        return getValue(for: atom)
    }

    // TODO: Move to Transaction.
    @usableFromInline
    func addTermination(_ termination: Termination, in transaction: Transaction) {
        guard !transaction.isTerminated else {
            return termination()
        }

        transaction.terminations.append(termination)
    }
}

private extension RootAtomStore {
    init(
        store: Store?,
        overrides: Overrides? = nil,
        observers: [AtomObserver] = []
    ) {
        self.store = store
        self.overrides = overrides
        self.observers = observers
    }

    func registerIfAbsent<Node: Atom>(atom: Node) {
        guard let store = store else {
            return
        }

        let key = AtomKey(atom)
        let isNewlyRegistered = store.state.atomStates.insertValueIfAbsent(
            forKey: key,
            default: ConcreteAtomState(atom: atom, value: nil)
        )

        if isNewlyRegistered {
            // Notify atom registration to observers.
            for observer in observers {
                observer.atomAssigned(atom: atom)
            }
        }
    }

    /// Returns a loader context that will not accept subsequent operations to the store when terminated.
    func prepareTransaction<Node: Atom>(for atom: Node) -> AtomLoaderContext<Node.Loader.Value> {
        let key = AtomKey(atom)
        let oldDependencies = invalidate(for: key)
        let transaction = Transaction(key: key) {
            guard let store = store else {
                return
            }

            let dependencies = store.graph.dependencies[key] ?? []
            let obsoletedDependencies = oldDependencies.subtracting(dependencies)

            checkReleaseDependencies(obsoletedDependencies, for: key)
        }

        store?.state.transactions[key] = transaction

        return AtomLoaderContext(store: self, transaction: transaction) { value, updatesDependentsOnNextRunLoop in
            update(atom: atom, with: value, updatesDependentsOnNextRunLoop: updatesDependentsOnNextRunLoop)
        }
    }

    func getValue<Node: Atom>(for atom: Node) -> Node.Loader.Value {
        var state = getCachedState(for: atom)

        if let value = state?.value {
            return value
        }

        let key = AtomKey(atom)
        let value = getNewValue(for: atom)

        state?.value = value
        store?.state.atomStates[key] = state

        // Notify value changes.
        notifyChangesToObservers(of: atom, value: value)

        return value
    }

    func getNewValue<Node: Atom>(for atom: Node) -> Node.Loader.Value {
        let context = prepareTransaction(for: atom)
        let value: Node.Loader.Value

        if let overrideValue = overrides?.value(for: atom) {
            // Set the override value.
            value = atom._loader.handle(context: context, with: overrideValue)
        }
        else {
            value = atom._loader.get(context: context)
        }

        return value
    }

    func getCachedState<Node: Atom>(for atom: Node) -> ConcreteAtomState<Node>? {
        let key = AtomKey(atom)

        guard let baseState = store?.state.atomStates[key] else {
            return nil
        }

        guard let state = baseState as? ConcreteAtomState<Node> else {
            assertionFailure(
                """
                The type of the given atom's value and the cached value did not match.
                There might be duplicate keys, make sure that the keys for all atom types are unique.

                Atom type: \(Node.self)
                Key type: \(type(of: atom.key))
                Invalid state type: \(type(of: baseState))
                """
            )

            // Release invalid registration.
            release(for: key)
            return nil
        }

        return state
    }

    func notifyUpdate(for key: AtomKey, updatesDependentsOnNextRunLoop: Bool = false) {
        guard let store = store else {
            return
        }

        // Notifying update for view subscriptions takes precedence.
        if let subscriptions = store.state.subscriptions[key].map({ ContiguousArray($0.values) }) {
            for subscription in subscriptions {
                subscription.notifyUpdate()
            }
        }

        // Notify update to downstream atoms.
        func notifyUpdateToDependents() {
            guard let children = store.graph.children[key] else {
                return
            }

            for child in children {
                let state = store.state.atomStates[child]
                state?.reset(with: self)
            }
        }

        if updatesDependentsOnNextRunLoop {
            RunLoop.current.perform {
                notifyUpdateToDependents()
            }
        }
        else {
            notifyUpdateToDependents()
        }
    }

    func update<Node: Atom>(
        atom: Node,
        with value: Node.Loader.Value,
        updatesDependentsOnNextRunLoop: Bool = false
    ) {
        guard let store = store else {
            return
        }

        let key = AtomKey(atom)
        var state = getCachedState(for: atom)
        let oldValue = state?.value

        state?.value = value
        store.state.atomStates[key] = state

        // Do not notify update if the value is equivalent to the old value.
        if let oldValue = oldValue, !atom._loader.shouldNotifyUpdate(newValue: value, oldValue: oldValue) {
            return
        }

        // Notify update to the downstream atoms or views.
        notifyUpdate(for: key, updatesDependentsOnNextRunLoop: updatesDependentsOnNextRunLoop)

        // Notify new value.
        notifyChangesToObservers(of: atom, value: value)
    }

    func checkRelease(for key: AtomKey) {
        guard let store = store else {
            return
        }

        // Do not release atoms marked as `KeepAlive`.
        let shouldKeepAlive = store.state.atomStates[key]?.shouldKeepAlive ?? false
        let shouldRelease =
            !shouldKeepAlive
            && store.graph.children.isEmptyOrNil(forKey: key)
            && store.state.subscriptions.isEmptyOrNil(forKey: key)

        guard shouldRelease else {
            return
        }

        release(for: key)
    }

    func release(for key: AtomKey) {
        guard let store = store else {
            return
        }

        let dependencies = invalidate(for: key)
        let atomState = store.state.atomStates.removeValue(forKey: key)

        store.graph.children.removeValue(forKey: key)
        store.state.subscriptions.removeValue(forKey: key)
        atomState?.notifyUnassigned(to: observers)

        checkReleaseDependencies(dependencies, for: key)
    }

    func checkReleaseDependencies(_ dependencies: Set<AtomKey>, for key: AtomKey) {
        guard let store = store else {
            return
        }

        // Recursively release dependencies.
        for dependency in dependencies {
            store.graph.children[dependency]?.remove(key)
            checkRelease(for: dependency)
        }
    }

    /// Terminates an atom associated with the given key bye the following steps.
    ///
    /// 1. Run all termination processes of the atom.
    /// 2. Remove the current transaction and mark it as terminated.
    /// 3. Temporarily remove the dependencies.
    func invalidate(for key: AtomKey) -> Set<AtomKey> {
        guard let store = store else {
            return []
        }

        // Remove the current transaction and then terminate to prevent current transaction
        // to watch new values or add terminations.
        store.state.transactions.removeValue(forKey: key)?.terminate()
        // Remove dependencies but do not release them recursively.
        return store.graph.dependencies.removeValue(forKey: key) ?? []
    }

    func notifyChangesToObservers<Node: Atom>(of atom: Node, value: Node.Loader.Value) {
        guard !observers.isEmpty else {
            return
        }

        let snapshot = Snapshot(atom: atom, value: value) {
            update(atom: atom, with: value)
        }

        for observer in observers {
            observer.atomChanged(snapshot: snapshot)
        }
    }
}

private extension Dictionary {
    func isEmptyOrNil(forKey key: Key) -> Bool where Value: Collection {
        guard let collection = self[key] else {
            return true
        }

        return collection.isEmpty
    }

    mutating func insertValueIfAbsent(forKey key: Key, default defaultValue: @autoclosure () -> Value) -> Bool {
        withUnsafeMutablePointer(to: &self[key]) { pointer in
            guard pointer.pointee == nil else {
                return false
            }
            pointer.pointee = defaultValue()
            return true
        }
    }
}
