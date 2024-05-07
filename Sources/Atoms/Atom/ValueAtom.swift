/// An atom type that provides a read-only value.
///
/// The value is cached until it will no longer be watched or any of watching atoms will notify update.
/// This atom can be used to combine one or more other atoms and transform result to another value.
/// Moreover, it can also be used to do dependency injection in compile safe and overridable for testing,
/// by providing a dependency instance required in another atom.
///
/// ## Output Value
///
/// Self.Value
///
/// ## Example
///
/// ```swift
/// struct CharacterCountAtom: ValueAtom, Hashable {
///     func value(context: Context) -> Int {
///         let text = context.watch(TextAtom())
///         return text.count
///     }
/// }
///
/// struct CharacterCountView: View {
///     @Watch(CharacterCountAtom())
///     var count
///
///     var body: some View {
///         Text("Character count: \(count)")
///     }
/// }
/// ```
///
public protocol ValueAtom: Atom {
    /// The type of value that this atom produces.
    associatedtype Value

    /// Creates a constant value to be provided via this atom.
    ///
    /// This method is called only when this atom is actually used, and is cached until it will
    /// no longer be watched or any of watching atoms will be updated.
    ///
    /// - Parameter context: A context structure to read, watch, and otherwise
    ///                      interact with other atoms.
    ///
    /// - Returns: A constant value.
    @MainActor
    func value(context: Context) -> Value
}

public extension ValueAtom {
    var producer: AtomProducer<Value, Coordinator> {
        AtomProducer { context in
            context.transaction(value)
        }
    }
}
