/// Declares side effects that are synchronized with the atom's lifecycle.
///
/// If this effect is attached to atoms via ``Atom/effect(context:)``, the effect is
/// initialized the first time the atom is used, and the instance will be retained
/// until the atom is released, thus it allows to declare stateful side effects.
///
/// SeeAlso: ``InitializeEffect``
/// SeeAlso: ``UpdateEffect``
/// SeeAlso: ``ReleaseEffect``
/// SeeAlso: ``MergedEffect``
@MainActor
public protocol AtomEffect {
    /// A type of the context structure to read, set, and otherwise interact
    /// with other atoms.
    typealias Context = AtomEffectContext

    /// A lifecycle event that is triggered when the atom is first used and initialized,
    /// or once it is released and re-initialized again.
    func initialized(context: Context)

    /// A lifecycle event that is triggered when the atom is updated.
    func updated(context: Context)

    /// A lifecycle event that is triggered when the atom is no longer watched and released.
    func released(context: Context)
}

public extension AtomEffect {
    func initialized(context: Context) {}
    func updated(context: Context) {}
    func released(context: Context) {}
}
