@usableFromInline
internal final class NewAtomStore {
    var graph = Graph()
    var state = StoreState()
}

@usableFromInline
@MainActor
internal protocol AtomStoreInteractor {
    func read<Node: Atom>(_ atom: Node) -> Node.State.Value

    func set<Node: StateAtom>(_ value: Node.Value, for atom: Node)

    func watch<Node: Atom, Downstream: Atom>(
        _ atom: Node,
        downstream: Downstream,
        shouldNotifyAfterUpdates: Bool
    ) -> Node.State.Value

    func watch<Node: Atom>(
        _ atom: Node,
        container: SubscriptionContainer.Wrapper,
        notifyUpdate: @escaping () -> Void
    ) -> Node.State.Value

    func refresh<Node: Atom>(_ atom: Node) async -> Node.State.Value where Node.State: RefreshableAtomState

    func reset<Node: Atom>(_ atom: Node)

    func notifyUpdate<Node: Atom>(of atom: Node)

    func addTermination<Node: Atom>(for atom: Node, _ termination: @MainActor @escaping () -> Void)

    func relay(observers: [AtomObserver]) -> AtomStoreInteractor
}

@usableFromInline
internal struct RootAtomStoreInteractor: AtomStoreInteractor {
    private weak var store: NewAtomStore?
    private let overrides: Overrides?
    private let observers: [AtomObserver]

    init(
        store: NewAtomStore,
        overrides: Overrides? = nil,
        observers: [AtomObserver] = []
    ) {
        self.store = store
        self.overrides = overrides
        self.observers = observers
    }

    @usableFromInline
    func read<Node: Atom>(_ atom: Node) -> Node.State.Value {
        getValue(of: atom, peek: true)
    }

    @usableFromInline
    func set<Node: StateAtom>(_ value: Node.Value, for atom: Node) {
        // Do nothing if the atom is not yet to be watched.
        guard let oldValue = getCachedValue(of: atom) else {
            return
        }

        let key = AtomKey(atom)
        let context = AtomRelationContext(atom: atom, store: self)

        atom.willSet(newValue: value, oldValue: oldValue, context: context)
        store?.state.values[key] = value
        notifyUpdate(of: atom)
        atom.didSet(newValue: value, oldValue: oldValue, context: context)

        // Notify new value.
        notifyChangesToObservers(of: atom, value: value)
    }

    @usableFromInline
    func watch<Node: Atom>(
        _ atom: Node,
        container: SubscriptionContainer.Wrapper,
        notifyUpdate: @escaping () -> Void
    ) -> Node.State.Value {
        guard let store = store else {
            return getValue(of: atom, peek: false)
        }

        let key = AtomKey(atom)
        let subscriptionKey = container.key
        let subscription = Subscription(notifyUpdate: notifyUpdate) { [weak store] in
            // Remove subscription from the store.
            store?.state.subscriptions[key]?.removeValue(forKey: subscriptionKey)
            // Release the atom if it is no longer watched to.
            checkAndRelease(for: key)
        }

        // Assign subscription to the container so the caller side can unsubscribe.
        container.assign(subscription: subscription, for: key)

        // Assign subscription to the store.
        store.state.subscriptions[key, default: [:]][subscriptionKey] = subscription

        return getValue(of: atom, peek: false)
    }

    @usableFromInline
    func watch<Node: Atom, Downstream: Atom>(
        _ atom: Node,
        downstream: Downstream,
        shouldNotifyAfterUpdates: Bool
    ) -> Node.State.Value {
        guard let store = store else {
            return getValue(of: atom, peek: false)
        }

        let key = AtomKey(atom)
        let downstreamKey = AtomKey(downstream)

        // Add an edge reference each other.
        store.graph.nodes[key, default: []].insert(downstreamKey)
        store.graph.dependencies[downstreamKey, default: []].insert(key)

        // TODO: Check shouldNotifyAfterUpdates

        return getValue(of: atom, peek: false)
    }

    @usableFromInline
    func refresh<Node: Atom>(_ atom: Node) async -> Node.State.Value where Node.State: RefreshableAtomState {
        // Release the value & the ongoing task, but keep upstream atoms alive until finishing refresh.
        let key = AtomKey(atom)
        let dependencies = release(for: key)
        let state = atom.makeState()
        let context = AtomStateContext(atom: atom, store: self)
        let value: Node.State.Value

        if let overrideValue = overrides?[atom] {
            value = await state.refreshOverride(with: overrideValue, context: context)
        }
        else {
            value = await state.refresh(context: context)
        }

        checkAndReleaseDependencies(of: key, oldDependencies: dependencies)

        return value
    }

    @usableFromInline
    func reset<Node: Atom>(_ atom: Node) {
        let key = AtomKey(atom)
        let dependencies = release(for: key)
        notifyUpdate(for: key)
        checkAndReleaseDependencies(of: key, oldDependencies: dependencies)
    }

    @usableFromInline
    func notifyUpdate<Node: Atom>(of atom: Node) {
        let key = AtomKey(atom)
        notifyUpdate(for: key)
    }

    @usableFromInline
    func addTermination<Node: Atom>(for atom: Node, _ termination: @MainActor @escaping () -> Void) {
        guard let store = store else {
            return termination()
        }

        let key = AtomKey(atom)
        let termination = Termination(termination)

        store.state.terminations[key, default: []].append(termination)
    }

    @usableFromInline
    func relay(observers: [AtomObserver]) -> AtomStoreInteractor {
        Self(
            store: store,
            overrides: overrides,
            observers: self.observers + observers
        )
    }
}

private extension RootAtomStoreInteractor {
    init(
        store: NewAtomStore?,
        overrides: Overrides? = nil,
        observers: [AtomObserver] = []
    ) {
        self.store = store
        self.overrides = overrides
        self.observers = observers
    }

    func getValue<Node: Atom>(of atom: Node, peek: Bool) -> Node.State.Value {
        guard let store = store else {
            return getNewValue(of: atom)
        }

        if let value = getCachedValue(of: atom) {
            return value
        }

        let key = AtomKey(atom)
        let value = getNewValue(of: atom)

        // Notify value changes.
        notifyChangesToObservers(of: atom, value: value)

        if !peek {
            store.state.values[key] = value
        }

        // TODO: KeepAlive

        // Notify the assignment to observers.
        // TODO: Reconsider when to call.
//        for observer in observers {
//            observer.atomAssigned(atom: atom)
//        }

        return value
    }

    func getNewValue<Node: Atom>(of atom: Node) -> Node.State.Value {
        let value: Node.State.Value

        if let overrideValue = overrides?[atom] {
            // Set the override value.
            value = overrideValue
        }
        else {
            let context = AtomStateContext(atom: atom, store: self)
            value = atom.makeState().value(context: context)
        }

        return value
    }

    func getCachedValue<Node: Atom>(of atom: Node) -> Node.State.Value? {
        let key = AtomKey(atom)

        guard let anyValue = store?.state.values[key] else {
            return nil
        }

        guard let value = anyValue as? Node.State.Value else {
            assertionFailure(
                """
                The type of the given atom's value and the cached value did not match.
                There might be duplicate keys, make sure that the keys for all atom types are unique.

                Atom type: \(Node.self)
                Key type: \(type(of: atom.key))
                Expected value type: \(Node.State.Value.self)
                Cached value type: \(type(of: anyValue))
                """
            )

            // Remove the invalid value.
            store?.state.values.removeValue(forKey: key)
            return nil
        }

        return value
    }

    func notifyUpdate(for key: AtomKey) {
        guard let store = store else {
            return
        }

        // Notifying update for view subscriptions takes precedence.
        if let subscriptions = store.state.subscriptions[key] {
            for subscription in subscriptions.values {
                subscription.notifyUpdate()
            }
        }

        // Notify update to downstream atoms.
        if let nodes = store.graph.nodes[key] {
            for node in nodes {
                let dependencies = release(for: node)
                // TODO: Check shouldNotifyUpdate
                notifyUpdate(for: node)
                checkAndReleaseDependencies(of: node, oldDependencies: dependencies)
            }
        }
    }

    func checkAndRelease(for key: AtomKey) {
        guard let store = store else {
            return
        }

        /// `true` if the atom has no downstream atoms.
        let hasNoDependents = store.graph.nodes[key]?.isEmpty ?? true
        /// `true` if the atom is not subscribed by views.
        let hasNoSubscriptions = store.state.subscriptions[key]?.isEmpty ?? true

        if hasNoDependents {
            store.graph.nodes.removeValue(forKey: key)
        }

        if hasNoSubscriptions {
            store.state.subscriptions.removeValue(forKey: key)
        }

        guard hasNoDependents && hasNoSubscriptions else {
            return
        }

        let dependencies = release(for: key)
        checkAndReleaseDependencies(of: key, oldDependencies: dependencies)
    }

    /// Release an atom associated by the specified key and return its dependencies.
    func release(for key: AtomKey) -> Set<AtomKey> {
        guard let store = store else {
            return []
        }

        defer {
            // Notify the unassignment to observers.
            // TODO:
    //        for observer in observers {
    //            observer.atomUnassigned(atom: atom)
    //        }
        }

        // Cleanup.
        store.state.values.removeValue(forKey: key)

        // Terminate.
        if let terminations = store.state.terminations.removeValue(forKey: key) {
            for termination in terminations {
                termination()
            }
        }

        return store.graph.dependencies.removeValue(forKey: key) ?? []
    }

    func checkAndReleaseDependencies(of key: AtomKey, oldDependencies: Set<AtomKey>) {
        guard let store = store else {
            return
        }

        let dependencies = store.graph.dependencies[key] ?? []
        let oldDependencies = oldDependencies.subtracting(dependencies)

        // Recursively release dependencies.
        for oldDependency in oldDependencies {
            // Remove this atom from the upstream atoms.
            store.graph.nodes[oldDependency]?.remove(key)

            // Release the upstream atoms as well.
            checkAndRelease(for: oldDependency)
        }
    }

    func notifyChangesToObservers<Node: Atom>(of atom: Node, value: Node.State.Value) {
        guard !observers.isEmpty else {
            return
        }

        let snapshot = Snapshot(atom: atom, value: value) {
            let key = AtomKey(atom)
            store?.state.values[key] = value
            notifyUpdate(for: key)
        }

        for observer in observers {
            observer.atomChanged(snapshot: snapshot)
        }
    }
}