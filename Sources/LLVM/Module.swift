#if SWIFT_PACKAGE
import cllvm
#endif

/// A `Context` represents execution states for the core LLVM IR system.
public class Context {
  internal let llvm: LLVMContextRef
  internal let ownsContext: Bool

  /// Retrieves the global context instance.
  public static let global = Context(llvm: LLVMGetGlobalContext()!)

  /// Creates a `Context` object using `LLVMContextCreate`
  public init() {
    llvm = LLVMContextCreate()
    ownsContext = true
  }

  /// Creates a `Context` object from an `LLVMContextRef` object.
  public init(llvm: LLVMContextRef, ownsContext: Bool = false) {
    self.llvm = llvm
    self.ownsContext = ownsContext
  }

  deinit {
    if ownsContext {
      LLVMContextDispose(llvm)
    }
  }
}

/// Represents the possible errors that can be thrown while interacting with a
/// `Module` object.
public enum ModuleError: Error, CustomStringConvertible {
  /// Thrown when a module does not pass the module verification process.
  /// Includes the reason the module did not pass verification.
  case didNotPassVerification(String)
  /// Thrown when a module cannot be printed at a given path.  Provides the
  /// erroneous path and a deeper reason why printing to that path failed.
  case couldNotPrint(path: String, error: String)
  /// Thrown when a module cannot emit bitcode because it contains erroneous
  /// declarations.
  case couldNotEmitBitCode(path: String)

  public var description: String {
    switch self {
    case .didNotPassVerification(let message):
      return "module did not pass verification: \(message)"
    case .couldNotPrint(let path, let error):
      return "could not print to file \(path): \(error)"
    case .couldNotEmitBitCode(let path):
      return "could not emit bitcode to file \(path) for an unknown reason"
    }
  }
}

/// A `Module` represents the top-level structure of an LLVM program. An LLVM
/// module is effectively a translation unit or a collection of translation
/// units merged together.
public final class Module: CustomStringConvertible {
  internal let llvm: LLVMModuleRef
  internal var ownsContext: Bool = true

  /// Creates a `Module` with the given name.
  ///
  /// - parameter name: The name of the module.
  /// - parameter context: The context to associate this module with.  If no
  ///   context is provided, one will be inferred.
  public init(name: String, context: Context? = nil) {

    // Ensure the LLVM initializer is called when the first module is created
    initializeLLVM()

    if let context = context {
      llvm = LLVMModuleCreateWithNameInContext(name, context.llvm)
      self.context = context
    } else {
      llvm = LLVMModuleCreateWithName(name)
      self.context = Context(llvm: LLVMGetModuleContext(llvm)!)
    }
  }

  /// Obtain the target triple for this module.
  var targetTriple: String {
    get {
      guard let id = LLVMGetTarget(llvm) else { return "" }
      return String(cString: id)
    }
    set { LLVMSetTarget(llvm, newValue) }
  }

  /// Returns the context associated with this module.
  public let context: Context

  /// Obtain the data layout for this module.
  public var dataLayout: TargetData {
    get { return TargetData(llvm: LLVMGetModuleDataLayout(llvm)) }
    set { LLVMSetModuleDataLayout(llvm, newValue.llvm) }
  }

  /// Returns a string describing the data layout associated with this module.
  public var dataLayoutString: String {
    get {
      guard let id = LLVMGetDataLayoutStr(llvm) else { return "" }
      return String(cString: id)
    }
    set { LLVMSetDataLayout(llvm, newValue) }
  }

  /// The identifier of this module.
  public var name: String {
    get {
      var count = 0
      guard let id = LLVMGetModuleIdentifier(llvm, &count) else { return "" }
      return String(cString: id)
    }
    set {
      LLVMSetModuleIdentifier(llvm, newValue, newValue.utf8.count)
    }
  }

  /// Retrieves the inline assembly for this module, if any.
  public var inlineAssembly: String {
    get {
      var length: Int = 0
      guard let id = LLVMGetModuleInlineAsm(llvm, &length) else { return "" }
      return String(cString: id)
    }
    set {
      LLVMSetModuleInlineAsm2(llvm, newValue, newValue.utf8.count)
    }
  }

  /// Print a representation of a module to a file at the given path.
  ///
  /// If the provided path is not suitable for writing, this function will throw
  /// `ModuleError.couldNotPrint`.
  ///
  /// - parameter path: The path to write the module's representation to.
  public func print(to path: String) throws {
    var err: UnsafeMutablePointer<Int8>?
    path.withCString { cString in
      let mutable = strdup(cString)
      LLVMPrintModuleToFile(llvm, mutable, &err)
      free(mutable)
    }
    if let err = err {
      defer { LLVMDisposeMessage(err) }
      throw ModuleError.couldNotPrint(path: path, error: String(cString: err))
    }
  }

  /// Writes the bitcode of elements in this module to a file at the given path.
  ///
  /// If the provided path is not suitable for writing, this function will throw
  /// `ModuleError.couldNotEmitBitCode`.
  ///
  /// - parameter path: The path to write the module's representation to.
  public func emitBitCode(to path: String) throws {
    let status = path.withCString { cString -> Int32 in
      let mutable = strdup(cString)
      defer { free(mutable) }
      return LLVMWriteBitcodeToFile(llvm, mutable)
    }

    if status != 0 {
      throw ModuleError.couldNotEmitBitCode(path: path)
    }
  }

  /// Verifies that this module is valid, taking the specified action if not.
  /// If this module did not pass verification, a description of any invalid
  /// constructs is provided with the thrown
  /// `ModuleError.didNotPassVerification` error.
  public func verify() throws {
    var message: UnsafeMutablePointer<Int8>?
    let status = Int(LLVMVerifyModule(llvm, LLVMReturnStatusAction, &message))
    if let message = message, status == 1 {
      defer { LLVMDisposeMessage(message) }
      throw ModuleError.didNotPassVerification(String(cString: message))
    }
  }

  /// Links the given module with this module.  If the link succeeds, this
  /// module will the composite of the two input modules.
  ///
  /// The result of this function is `true` if the link succeeds, or `false`
  /// otherwise - unlike `llvm::Linker::linkModules`.
  ///
  /// - parameter other: The module to link with this module.
  public func link(_ other: Module) -> Bool {
    // First clone the other module; `LLVMLinkModules2` consumes the source
    // module via a move and that module still owns its ModuleRef.
    let otherClone = LLVMCloneModule(other.llvm)
    // N.B. Returns `true` on error.
    return LLVMLinkModules2(self.llvm, otherClone) == 0
  }

  /// Retrieves the sequence of functions that make up this module.
  public var functions: AnySequence<Function> {
    var current = firstFunction
    return AnySequence<Function> {
      return AnyIterator<Function> {
        defer { current = current?.next() }
        return current
      }
    }
  }

  /// Retrieves the first function in this module, if there are any functions.
  public var firstFunction: Function? {
    guard let fn = LLVMGetFirstFunction(llvm) else { return nil }
    return Function(llvm: fn)
  }

  /// Retrieves the last function in this module, if there are any functions.
  public var lastFunction: Function? {
    guard let fn = LLVMGetLastFunction(llvm) else { return nil }
    return Function(llvm: fn)
  }

  /// Retrieves the first global in this module, if there are any globals.
  public var firstGlobal: Global? {
    guard let fn = LLVMGetFirstGlobal(llvm) else { return nil }
    return Global(llvm: fn)
  }

  /// Retrieves the last global in this module, if there are any globals.
  public var lastGlobal: Global? {
    guard let fn = LLVMGetLastGlobal(llvm) else { return nil }
    return Global(llvm: fn)
  }

  /// Retrieves the sequence of functions that make up this module.
  public var globals: AnySequence<Global> {
    var current = firstGlobal
    return AnySequence<Global> {
      return AnyIterator<Global> {
        defer { current = current?.next() }
        return current
      }
    }
  }

  /// Retrieves the sequence of aliases that make up this module.
  public var aliases: AnySequence<Alias> {
    var current = firstAlias
    return AnySequence<Alias> {
      return AnyIterator<Alias> {
        defer { current = current?.next() }
        return current
      }
    }
  }

  /// Retrieves the first alias in this module, if there are any aliases.
  public var firstAlias: Alias? {
    guard let fn = LLVMGetFirstGlobalAlias(llvm) else { return nil }
    return Alias(llvm: fn)
  }

  /// Retrieves the last alias in this module, if there are any aliases.
  public var lastAlias: Alias? {
    guard let fn = LLVMGetLastGlobalAlias(llvm) else { return nil }
    return Alias(llvm: fn)
  }

  /// The current debug metadata version number.
  public static var debugMetadataVersion: UInt32 {
    return LLVMDebugMetadataVersion();
  }

  /// The version of debug metadata that's present in this module.
  public var debugMetadataVersion: UInt32 {
    return LLVMGetModuleDebugMetadataVersion(self.llvm)
  }

  /// Strip debug info in the module if it exists.
  ///
  /// To do this, we remove all calls to the debugger intrinsics and any named
  /// metadata for debugging. We also remove debug locations for instructions.
  /// Return true if module is modified.
  public func stripDebugInfo() -> Bool {
    return LLVMStripModuleDebugInfo(self.llvm) != 0
  }

  /// Dump a representation of this module to stderr.
  public func dump() {
    LLVMDumpModule(llvm)
  }

  /// The full text IR of this module
  public var description: String {
    let cStr = LLVMPrintModuleToString(llvm)!
    defer { LLVMDisposeMessage(cStr) }
    return String(cString: cStr)
  }

  deinit {
    guard self.ownsContext else {
      return
    }
    LLVMDisposeModule(llvm)
  }
}

// MARK: Global Declarations

extension Module {
  /// Searches for and retrieves a global variable with the given name in this
  /// module if that name references an existing global variable.
  ///
  /// - parameter name: The name of the global to reference.
  ///
  /// - returns: A value representing the referenced global if it exists.
  public func global(named name: String) -> Global? {
    guard let ref = LLVMGetNamedGlobal(llvm, name) else { return nil }
    return Global(llvm: ref)
  }

  /// Searches for and retrieves a type with the given name in this module if
  /// that name references an existing type.
  ///
  /// - parameter name: The name of the type to create.
  ///
  /// - returns: A representation of the newly created type with the given name
  ///   or nil if such a representation could not be created.
  public func type(named name: String) -> IRType? {
    guard let type = LLVMGetTypeByName(llvm, name) else { return nil }
    return convertType(type)
  }

  /// Searches for and retrieves a function with the given name in this module
  /// if that name references an existing function.
  ///
  /// - parameter name: The name of the function to create.
  ///
  /// - returns: A representation of the newly created function with the given
  ///   name or nil if such a representation could not be created.
  public func function(named name: String) -> Function? {
    guard let fn = LLVMGetNamedFunction(llvm, name) else { return nil }
    return Function(llvm: fn)
  }

  /// Searches for and retrieves an alias with the given name in this module
  /// if that name references an existing alias.
  ///
  /// - parameter name: The name of the alias to search for.
  ///
  /// - returns: A representation of an alias with the given
  ///   name or nil if no such named alias exists.
  public func alias(named name: String) -> Alias? {
    guard let alias = LLVMGetNamedGlobalAlias(llvm, name, name.count) else { return nil }
    return Alias(llvm: alias)
  }

  /// Searches for and retrieves a comdat section with the given name in this
  /// module.  If none is found, one with that name is created and returned.
  ///
  /// - parameter name: The name of the comdat section to create.
  ///
  /// - returns: A representation of the newly created comdat section with the
  ///   given name.
  public func comdat(named name: String) -> Comdat {
    guard let comdat = LLVMGetOrInsertComdat(llvm, name) else { fatalError() }
    return Comdat(llvm: comdat)
  }

  /// Searches for and retrieves module-level named metadata with the given name
  /// in this module.  If none is found, one with that name is created and
  /// returned.
  ///
  /// - parameter name: The name of the comdat section to create.
  ///
  /// - returns: A representation of the newly created metadata with the
  ///   given name.
  public func metadata(named name: String) -> NamedMetadata {
    return NamedMetadata(module: self, name: name)
  }

  /// Build a named global of the given type.
  ///
  /// - parameter name: The name of the newly inserted global value.
  /// - parameter type: The type of the newly inserted global value.
  /// - parameter addressSpace: The optional address space where the global
  ///   variable resides.
  ///
  /// - returns: A value representing the newly inserted global variable.
  public func addGlobal(_ name: String, type: IRType, addressSpace: Int? = nil) -> Global {
    let val: LLVMValueRef
    if let addressSpace = addressSpace {
      val = LLVMAddGlobalInAddressSpace(llvm, type.asLLVM(), name, UInt32(addressSpace))
    } else {
      val = LLVMAddGlobal(llvm, type.asLLVM(), name)
    }
    return Global(llvm: val)
  }

  /// Build a named global of the given type.
  ///
  /// - parameter name: The name of the newly inserted global value.
  /// - parameter initializer: The initial value for the global variable.
  /// - parameter addressSpace: The optional address space where the global
  ///   variable resides.
  ///
  /// - returns: A value representing the newly inserted global variable.
  public func addGlobal(_ name: String, initializer: IRValue, addressSpace: Int? = nil) -> Global {
    let global = addGlobal(name, type: initializer.type)
    global.initializer = initializer
    return global
  }

  /// Build a named global string consisting of an array of `i8` type filled in
  /// with the nul terminated string value.
  ///
  /// - parameter name: The name of the newly inserted global string value.
  /// - parameter value: The character contents of the newly inserted global.
  ///
  /// - returns: A value representing the newly inserted global string variable.
  public func addGlobalString(name: String, value: String) -> Global {
    let length = value.utf8.count

    var global = addGlobal(name, type:
      ArrayType(elementType: IntType.int8, count: length + 1))

    global.alignment = Alignment(1)
    global.initializer = value

    return global
  }

  /// Build a named alias to a global value or a constant expression.
  ///
  /// Aliases, unlike function or variables, don’t create any new data. They are
  /// just a new symbol and metadata for an existing position.
  ///
  /// - parameter name: The name of the newly inserted alias.
  /// - parameter aliasee: The value or constant to alias.
  /// - parameter type: The type of the aliased value or expression.
  ///
  /// - returns: A value representing the newly created alias.
  public func addAlias(name: String, to aliasee: IRGlobal, type: IRType) -> Alias {
    return Alias(llvm: LLVMAddAlias(llvm, type.asLLVM(), aliasee.asLLVM(), name))
  }

  /// Append to the module-scope inline assembly blocks.
  ///
  /// A trailing newline is added if the given string doesn't have one.
  ///
  /// - parameter asm: The inline assembly expression template string.
  public func appendInlineAssembly(_ asm: String) {
    LLVMAppendModuleInlineAsm(llvm, asm, asm.count)
  }
}

// MARK: Module Flags

extension Module {
  /// Represents flags that describe information about the module for use by
  /// an external entity e.g. the dynamic linker.
  ///
  /// - Warning: Module flags are not a general runtime metadata infrastructure,
  ///   and may be stripped by LLVM.  As of the current release, LLVM hardcodes
  ///   support for object-file emission of module flags related to
  ///   Objective-C.
  public class Flags {
    /// Enumerates the supported behaviors for resolving collisions when two
    /// module flags share the same key.  These collisions can occur when the
    /// different flags are inserted under the same key, or when modules
    /// containing flags under the same key are merged.
    public enum Behavior {
      /// Emits an error if two values disagree, otherwise the resulting value
      /// is that of the operands.
      case error
      /// Emits a warning if two values disagree. The result value will be the
      /// operand for the flag from the first module being linked.
      case warning
      /// Adds a requirement that another module flag be present and have a
      /// specified value after linking is performed. The value must be a
      /// metadata pair, where the first element of the pair is the ID of the
      /// module flag to be restricted, and the second element of the pair is
      /// the value the module flag should be restricted to. This behavior can
      /// be used to restrict the allowable results (via triggering of an error)
      /// of linking IDs with the **Override** behavior.
      case require
      /// Uses the specified value, regardless of the behavior or value of the
      /// other module. If both modules specify **Override**, but the values
      /// differ, an error will be emitted.
      case override
      /// Appends the two values, which are required to be metadata nodes.
      case append
      /// Appends the two values, which are required to be metadata
      /// nodes. However, duplicate entries in the second list are dropped
      /// during the append operation.
      case appendUnique

      fileprivate init(raw: LLVMModuleFlagBehavior) {
        switch raw {
        case LLVMModuleFlagBehaviorError:
          self = .error
        case LLVMModuleFlagBehaviorWarning:
          self = .warning
        case LLVMModuleFlagBehaviorRequire:
          self = .require
        case LLVMModuleFlagBehaviorOverride:
          self = .override
        case LLVMModuleFlagBehaviorAppend:
          self = .append
        case LLVMModuleFlagBehaviorAppendUnique:
          self = .appendUnique
        default:
          fatalError("Unknown behavior kind")
        }
      }

      fileprivate static let behaviorMapping: [Behavior: LLVMModuleFlagBehavior] = [
        .error: LLVMModuleFlagBehaviorError,
        .warning: LLVMModuleFlagBehaviorWarning,
        .require: LLVMModuleFlagBehaviorRequire,
        .override: LLVMModuleFlagBehaviorOverride,
        .append: LLVMModuleFlagBehaviorAppend,
        .appendUnique: LLVMModuleFlagBehaviorAppendUnique,
      ]
    }

    /// Represents an entry in the module flags structure.
    public struct Entry {
      fileprivate let base: Flags
      fileprivate let index: UInt32

      /// The conflict behavior of this flag.
      public var behavior: Behavior {
        let raw = LLVMModuleFlagEntriesGetFlagBehavior(self.base.llvm, self.index)
        return Behavior(raw: raw)
      }

      /// The key this flag was inserted with.
      public var key: String {
        var count = 0
        guard let key = LLVMModuleFlagEntriesGetKey(self.base.llvm, self.index, &count) else { return "" }
        return String(cString: key)
      }

      /// The metadata value associated with this flag.
      public var metadata: IRMetadata {
        return AnyMetadata(llvm: LLVMModuleFlagEntriesGetMetadata(self.base.llvm, self.index))
      }
    }

    private let llvm: OpaquePointer?
    private let bounds: Int
    fileprivate init(llvm: OpaquePointer?, bounds: Int) {
      self.llvm = llvm
      self.bounds = bounds
    }

    deinit {
      guard let ptr = llvm else { return }
      LLVMDisposeModuleFlagsMetadata(ptr)
    }

    /// Retrieves a flag at the given index.
    ///
    /// - Parameter index: The index to retrieve.
    ///
    /// - Returns: An entry describing the flag at the given index.
    public subscript(_ index: Int) -> Entry {
      precondition(index >= 0 && index < self.bounds, "Index out of bounds")
      return Entry(base: self, index: UInt32(index))
    }

    public var count: Int {
      return self.bounds
    }
  }

  /// Add a module-level flag to the module-level flags metadata.
  ///
  /// - Parameters:
  ///   - name: The key for this flag.
  ///   - value: The metadata node to insert as the value for this flag.
  ///   - behavior: The resolution strategy to apply should the key for this
  ///     flag conflict with an existing flag.
  public func addFlag(named name: String, value: IRMetadata, behavior: Flags.Behavior) {
    let raw = Flags.Behavior.behaviorMapping[behavior]!
    LLVMAddModuleFlag(llvm, raw, name, name.count, value.asMetadata())
  }

  /// A convenience for inserting constant values as module-level flags.
  ///
  /// - Parameters:
  ///   - name: The key for this flag.
  ///   - value: The constant value to insert as the metadata for this flag.
  ///   - behavior: The resolution strategy to apply should the key for this
  ///     flag conflict with an existing flag.
  public func addFlag(named name: String, constant: IRConstant, behavior: Flags.Behavior) {
    let raw = Flags.Behavior.behaviorMapping[behavior]!
    LLVMAddModuleFlag(llvm, raw, name, name.count, LLVMValueAsMetadata(constant.asLLVM()))
  }

  /// Retrieves the module-level flags, if they exist.
  public var flags: Flags? {
    var len = 0
    guard let raw = LLVMCopyModuleFlagsMetadata(llvm, &len) else { return nil }
    return Flags(llvm: raw, bounds: len)
  }
}

extension Bool {
  internal var llvm: LLVMBool {
    return self ? 1 : 0
  }
}
