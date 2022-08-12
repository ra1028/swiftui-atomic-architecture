import Combine

public struct ObservableObjectAtomValue<ObjectType: ObservableObject>: AtomValue {
    public typealias Value = ObjectType

    private let makeObject: @MainActor (AtomRelationContext) -> ObjectType

    internal init(makeObject: @MainActor @escaping (AtomRelationContext) -> ObjectType) {
        self.makeObject = makeObject
    }

    public func get(context: Context) -> ObjectType {
        let object = makeObject(context.atomContext)
        let cancellable = object.objectWillChange.sink { [weak object] _ in
            guard let object = object else {
                return
            }

            context.update(with: object)
        }

        context.addTermination(cancellable.cancel)
        return object
    }

    // TODO: Override
}