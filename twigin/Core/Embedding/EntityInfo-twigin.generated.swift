// Generated using the ObjectBox Swift Generator — https://objectbox.io
// DO NOT EDIT

// swiftlint:disable all
import ObjectBox
import Foundation

// MARK: - Entity metadata

extension ArticleDataModel: ObjectBox.Entity {}

extension ArticleDataModel: ObjectBox.__EntityRelatable {
    internal typealias EntityType = ArticleDataModel

    internal var _id: EntityId<ArticleDataModel> {
        return EntityId<ArticleDataModel>(self.id.value)
    }
}

extension ArticleDataModel: ObjectBox.EntityInspectable {
    internal typealias EntityBindingType = NewsArticleDataModelBinding

    /// Generated metadata used by ObjectBox to persist the entity.
    internal static let entityInfo = ObjectBox.EntityInfo(name: "NewsArticleDataModel", id: 2)

    internal static let entityBinding = EntityBindingType()

    fileprivate static func buildEntity(modelBuilder: ObjectBox.ModelBuilder) throws {
        let entityBuilder = try modelBuilder.entityBuilder(for: ArticleDataModel.self, id: 2, uid: 1347469140805829376)
        try entityBuilder.addProperty(name: "id", type: PropertyType.long, flags: [.id], id: 1, uid: 2843959564389858560)
        try entityBuilder.addProperty(name: "noteId", type: PropertyType.string, id: 6, uid: 6569281597192037376)
        try entityBuilder.addProperty(name: "title", type: PropertyType.string, id: 2, uid: 8361989269940618496)
        try entityBuilder.addProperty(name: "content", type: PropertyType.string, id: 3, uid: 8775985421856403200)
        try entityBuilder.addProperty(name: "url", type: PropertyType.string, id: 4, uid: 2974810375726798592)
        try entityBuilder.addProperty(name: "publishDate", type: PropertyType.date, id: 5, uid: 75201656904859136)
        try entityBuilder.addProperty(name: "embedding", type: PropertyType.floatVector, id: 7, uid: 6479909303570848256)

        try entityBuilder.lastProperty(id: 7, uid: 6479909303570848256)
    }
}

extension ArticleDataModel {
    /// Generated entity property information.
    ///
    /// You may want to use this in queries to specify fetch conditions, for example:
    ///
    ///     box.query { NewsArticleDataModel.id == myId }
    internal static var id: Property<ArticleDataModel, Id, Id> { return Property<ArticleDataModel, Id, Id>(propertyId: 1, isPrimaryKey: true) }
    /// Generated entity property information.
    ///
    /// You may want to use this in queries to specify fetch conditions, for example:
    ///
    ///     box.query { NewsArticleDataModel.noteId.startsWith("X") }
    internal static var noteId: Property<ArticleDataModel, String, Void> { return Property<ArticleDataModel, String, Void>(propertyId: 6, isPrimaryKey: false) }
    /// Generated entity property information.
    ///
    /// You may want to use this in queries to specify fetch conditions, for example:
    ///
    ///     box.query { NewsArticleDataModel.title.startsWith("X") }
    internal static var title: Property<ArticleDataModel, String, Void> { return Property<ArticleDataModel, String, Void>(propertyId: 2, isPrimaryKey: false) }
    /// Generated entity property information.
    ///
    /// You may want to use this in queries to specify fetch conditions, for example:
    ///
    ///     box.query { NewsArticleDataModel.content.startsWith("X") }
    internal static var content: Property<ArticleDataModel, String, Void> { return Property<ArticleDataModel, String, Void>(propertyId: 3, isPrimaryKey: false) }
    /// Generated entity property information.
    ///
    /// You may want to use this in queries to specify fetch conditions, for example:
    ///
    ///     box.query { NewsArticleDataModel.url.startsWith("X") }
    internal static var url: Property<ArticleDataModel, String?, Void> { return Property<ArticleDataModel, String?, Void>(propertyId: 4, isPrimaryKey: false) }
    /// Generated entity property information.
    ///
    /// You may want to use this in queries to specify fetch conditions, for example:
    ///
    ///     box.query { NewsArticleDataModel.publishDate > 1234 }
    internal static var publishDate: Property<ArticleDataModel, Date, Void> { return Property<ArticleDataModel, Date, Void>(propertyId: 5, isPrimaryKey: false) }
    /// Generated entity property information.
    ///
    /// You may want to use this in queries to specify fetch conditions, for example:
    ///
    ///     box.query { NewsArticleDataModel.embedding.isGreaterThan(value) }
    internal static var embedding: Property<ArticleDataModel, FloatArrayPropertyType, Void> { return Property<ArticleDataModel, FloatArrayPropertyType, Void>(propertyId: 7, isPrimaryKey: false) }

    fileprivate func __setId(identifier: ObjectBox.Id) {
        self.id = Id(identifier)
    }
}

extension ObjectBox.Property where E == ArticleDataModel {
    /// Generated entity property information.
    ///
    /// You may want to use this in queries to specify fetch conditions, for example:
    ///
    ///     box.query { .id == myId }

    internal static var id: Property<ArticleDataModel, Id, Id> { return Property<ArticleDataModel, Id, Id>(propertyId: 1, isPrimaryKey: true) }

    /// Generated entity property information.
    ///
    /// You may want to use this in queries to specify fetch conditions, for example:
    ///
    ///     box.query { .noteId.startsWith("X") }

    internal static var noteId: Property<ArticleDataModel, String, Void> { return Property<ArticleDataModel, String, Void>(propertyId: 6, isPrimaryKey: false) }

    /// Generated entity property information.
    ///
    /// You may want to use this in queries to specify fetch conditions, for example:
    ///
    ///     box.query { .title.startsWith("X") }

    internal static var title: Property<ArticleDataModel, String, Void> { return Property<ArticleDataModel, String, Void>(propertyId: 2, isPrimaryKey: false) }

    /// Generated entity property information.
    ///
    /// You may want to use this in queries to specify fetch conditions, for example:
    ///
    ///     box.query { .content.startsWith("X") }

    internal static var content: Property<ArticleDataModel, String, Void> { return Property<ArticleDataModel, String, Void>(propertyId: 3, isPrimaryKey: false) }

    /// Generated entity property information.
    ///
    /// You may want to use this in queries to specify fetch conditions, for example:
    ///
    ///     box.query { .url.startsWith("X") }

    internal static var url: Property<ArticleDataModel, String?, Void> { return Property<ArticleDataModel, String?, Void>(propertyId: 4, isPrimaryKey: false) }

    /// Generated entity property information.
    ///
    /// You may want to use this in queries to specify fetch conditions, for example:
    ///
    ///     box.query { .publishDate > 1234 }

    internal static var publishDate: Property<ArticleDataModel, Date, Void> { return Property<ArticleDataModel, Date, Void>(propertyId: 5, isPrimaryKey: false) }

    /// Generated entity property information.
    ///
    /// You may want to use this in queries to specify fetch conditions, for example:
    ///
    ///     box.query { .embedding.isNotNil() }

    internal static var embedding: Property<ArticleDataModel, FloatArrayPropertyType, Void> { return Property<ArticleDataModel, FloatArrayPropertyType, Void>(propertyId: 7, isPrimaryKey: false) }

}


/// Generated service type to handle persisting and reading entity data. Exposed through `NewsArticleDataModel.EntityBindingType`.
internal final class NewsArticleDataModelBinding: ObjectBox.EntityBinding, Sendable {
    internal typealias EntityType = ArticleDataModel
    internal typealias IdType = Id

    internal required init() {}

    internal func generatorBindingVersion() -> Int { 1 }

    internal func setEntityIdUnlessStruct(of entity: EntityType, to entityId: ObjectBox.Id) {
        entity.__setId(identifier: entityId)
    }

    internal func entityId(of entity: EntityType) -> ObjectBox.Id {
        return entity.id.value
    }

    internal func collect(fromEntity entity: EntityType, id: ObjectBox.Id,
                                  propertyCollector: ObjectBox.FlatBufferBuilder, store: ObjectBox.Store) throws {
        let propertyOffset_noteId = propertyCollector.prepare(string: entity.noteId)
        let propertyOffset_title = propertyCollector.prepare(string: entity.title)
        let propertyOffset_content = propertyCollector.prepare(string: entity.content)
        let propertyOffset_url = propertyCollector.prepare(string: entity.url)
        let propertyOffset_embedding = propertyCollector.prepare(values: entity.embedding)

        propertyCollector.collect(id, at: 2 + 2 * 1)
        propertyCollector.collect(entity.publishDate, at: 2 + 2 * 5)
        propertyCollector.collect(dataOffset: propertyOffset_noteId, at: 2 + 2 * 6)
        propertyCollector.collect(dataOffset: propertyOffset_title, at: 2 + 2 * 2)
        propertyCollector.collect(dataOffset: propertyOffset_content, at: 2 + 2 * 3)
        propertyCollector.collect(dataOffset: propertyOffset_url, at: 2 + 2 * 4)
        propertyCollector.collect(dataOffset: propertyOffset_embedding, at: 2 + 2 * 7)
    }

    internal func createEntity(entityReader: ObjectBox.FlatBufferReader, store: ObjectBox.Store) -> EntityType {
        let entity = ArticleDataModel()

        entity.id = entityReader.read(at: 2 + 2 * 1)
        entity.noteId = entityReader.read(at: 2 + 2 * 6)
        entity.title = entityReader.read(at: 2 + 2 * 2)
        entity.content = entityReader.read(at: 2 + 2 * 3)
        entity.url = entityReader.read(at: 2 + 2 * 4)
        entity.publishDate = entityReader.read(at: 2 + 2 * 5)
        entity.embedding = entityReader.read(at: 2 + 2 * 7)

        return entity
    }
}


/// Helper function that allows calling Enum(rawValue: value) with a nil value, which will return nil.
fileprivate func optConstruct<T: RawRepresentable>(_ type: T.Type, rawValue: T.RawValue?) -> T? {
    guard let rawValue = rawValue else { return nil }
    return T(rawValue: rawValue)
}

// MARK: - Store setup

fileprivate func cModel() throws -> OpaquePointer {
    let modelBuilder = try ObjectBox.ModelBuilder()
    try ArticleDataModel.buildEntity(modelBuilder: modelBuilder)
    modelBuilder.lastEntity(id: 2, uid: 1347469140805829376)
    return modelBuilder.finish()
}

extension ObjectBox.Store {
    /// A store with a fully configured model. Created by the code generator with your model's metadata in place.
    ///
    /// # In-memory database
    /// To use a file-less in-memory database, instead of a directory path pass `memory:` 
    /// together with an identifier string:
    /// ```swift
    /// let inMemoryStore = try Store(directoryPath: "memory:test-db")
    /// ```
    ///
    /// - Parameters:
    ///   - directoryPath: The directory path in which ObjectBox places its database files for this store,
    ///     or to use an in-memory database `memory:<identifier>`.
    ///   - maxDbSizeInKByte: Limit of on-disk space for the database files. Default is `1024 * 1024` (1 GiB).
    ///   - fileMode: UNIX-style bit mask used for the database files; default is `0o644`.
    ///     Note: directories become searchable if the "read" or "write" permission is set (e.g. 0640 becomes 0750).
    ///   - maxReaders: The maximum number of readers.
    ///     "Readers" are a finite resource for which we need to define a maximum number upfront.
    ///     The default value is enough for most apps and usually you can ignore it completely.
    ///     However, if you get the maxReadersExceeded error, you should verify your
    ///     threading. For each thread, ObjectBox uses multiple readers. Their number (per thread) depends
    ///     on number of types, relations, and usage patterns. Thus, if you are working with many threads
    ///     (e.g. in a server-like scenario), it can make sense to increase the maximum number of readers.
    ///     Note: The internal default is currently around 120. So when hitting this limit, try values around 200-500.
    ///   - readOnly: Opens the database in read-only mode, i.e. not allowing write transactions.
    ///
    /// - important: This initializer is created by the code generator. If you only see the internal `init(model:...)`
    ///              initializer, trigger code generation by building your project.
    internal convenience init(directoryPath: String, maxDbSizeInKByte: UInt64 = 1024 * 1024,
                            fileMode: UInt32 = 0o644, maxReaders: UInt32 = 0, readOnly: Bool = false) throws {
        try self.init(
            model: try cModel(),
            directory: directoryPath,
            maxDbSizeInKByte: maxDbSizeInKByte,
            fileMode: fileMode,
            maxReaders: maxReaders,
            readOnly: readOnly)
    }
}

// swiftlint:enable all
