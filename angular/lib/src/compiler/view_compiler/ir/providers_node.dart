import '../../compile_metadata.dart';
import '../../output/output_ast.dart' as o;
import '../../template_ast.dart';
import '../../view_compiler/view_compiler_utils.dart';
import 'provider_source.dart';

/// Resolves and builds Providers for a single compile element that represents
/// a template node.
class ProvidersNode {
  final ProvidersNodeHost _host;
  final ProvidersNode _parent;

  /// Maps from a provider token to expression that will return instance
  /// at runtime. Builtin(s) are populated eagerly, ProviderAst based
  /// instances are added on demand.
  final _instances = CompileTokenMap<ProviderSource>();

  /// We track which providers are just 'useExisting' for another provider on
  /// this component. This way, we can detect when we don't need to generate
  /// a getter for them.
  final _aliases = CompileTokenMap<List<CompileTokenMetadata>>();
  final _aliasedProviders = CompileTokenMap<CompileTokenMetadata>();

  /// Indicates that ProvidersNode is on a host AppView. Used to determine
  /// how to reach correct dynamic injector.
  final bool _isAppViewHost;

  final CompileTokenMap<ProviderAst> _resolvedProviders =
      CompileTokenMap<ProviderAst>();

  ProvidersNode(this._host, this._parent, this._isAppViewHost);

  bool containsLocalProvider(CompileTokenMetadata token) =>
      _instances.containsKey(token);

  bool isAliasedProvider(CompileTokenMetadata token) =>
      _aliasedProviders.containsKey(token);

  List<CompileTokenMetadata> getAliases(CompileTokenMetadata providerToken) =>
      _aliases.get(providerToken);

  /// Adds a builtin local provider for a template node.
  void add(CompileTokenMetadata token, o.Expression providerValue) {
    _instances.add(token, BuiltInSource(token, providerValue));
  }

  ProviderSource get(CompileTokenMetadata token) => _instances.get(token);

  /// Given a list of directives (and component itself), adds providers for
  /// each directive at this node. Code generators that want to build
  /// instances can handle the createProviderInstance callback on the
  /// host interface.
  ///
  /// If [deferredComponent] is non-null, this node represents a deferred
  /// generic component with type arguments. In such a case, the
  /// [deferredComponentTypeArguments] should be used to instantiate the
  /// component provider with explicit type arguments. For non-deferred generic
  /// components we can really on the provider's field type to specify type
  /// arguments, but for deferred components the field type is dynamic.
  void addDirectiveProviders(
    final List<ProviderAst> providerList,
    final List<CompileDirectiveMetadata> directives, {
    CompileIdentifierMetadata deferredComponent,
    List<o.OutputType> deferredComponentTypeArguments,
  }) {
    // Create a lookup map from token to provider.
    for (ProviderAst provider in providerList) {
      _resolvedProviders.add(provider.token, provider);
    }
    // Create all the provider instances, some in the view constructor (eager),
    // some as getters (eager=false). We rely on the fact that they are
    // already sorted topologically.
    for (ProviderAst resolvedProvider in providerList) {
      if (resolvedProvider.providerType ==
          ProviderAstType.FunctionalDirective) {
        continue;
      }
      // One or more(multi) sources when built will return provider value
      // expressions.
      var providerSources = <ProviderSource>[];
      var isLocalAlias = false;
      CompileDirectiveMetadata directiveMetadata;
      for (var provider in resolvedProvider.providers) {
        ProviderSource providerSource;
        if (provider.useExisting != null) {
          // If this provider is just an alias for another provider on this
          // component, we don't need to generate a getter.
          if (_instances.containsKey(provider.useExisting) &&
              !resolvedProvider.eager &&
              !resolvedProvider.multiProvider) {
            isLocalAlias = true;
            break;
          }
          // Given the token and visibility defined by providerType,
          // get value based on existing expression mapped to token.
          providerSource = _getDependency(
              CompileDiDependencyMetadata(token: provider.useExisting));
          directiveMetadata = null;
        } else if (provider.useFactory != null) {
          providerSource =
              _addFactoryProvider(provider, resolvedProvider.providerType);
        } else if (provider.useClass != null) {
          var classType = provider.useClass.identifier;
          if (classType == deferredComponent) {
            // This provider represents a deferred generic component. Since the
            // field type of deferred components is always dynamic, we must
            // explicitly type the component constructor when creating this
            // provider instance.
            providerSource = _addClassProvider(
              provider,
              resolvedProvider.providerType,
              typeArguments: deferredComponentTypeArguments,
            );
          } else {
            providerSource =
                _addClassProvider(provider, resolvedProvider.providerType);
          }
          // Check if class is a directive and keep track of directiveMetadata
          // for the directive so we can determine if the provider has
          // an associated change detector class.
          for (var dir in directives) {
            if (dir.identifier == classType) {
              directiveMetadata = dir;
              break;
            }
          }
        } else {
          providerSource = LiteralValueSource(
              provider.token, convertValueToOutputAst(provider.useValue));
        }
        providerSources.add(providerSource);
      }
      if (isLocalAlias) {
        // This provider is just an alias for an existing field/instance
        // on the same view class, so just add the existing reference for this
        // token.
        var provider = resolvedProvider.providers.single;
        var alias = provider.useExisting;
        if (_aliasedProviders.containsKey(alias)) {
          alias = _aliasedProviders.get(alias);
        }
        if (!_aliases.containsKey(alias)) {
          _aliases.add(alias, <CompileTokenMetadata>[]);
        }
        _aliases.get(alias).add(provider.token);
        _aliasedProviders.add(resolvedProvider.token, alias);
        _instances.add(resolvedProvider.token, _instances.get(alias));
      } else {
        var token = resolvedProvider.token;
        _instances.add(
            token,
            _host.createProviderInstance(resolvedProvider, directiveMetadata,
                providerSources, _instances.size));
      }
    }
  }

  ProviderSource _addFactoryProvider(
      CompileProviderMetadata provider, ProviderAstType providerType) {
    var parameters = <ProviderSource>[];
    for (var paramDep in provider.deps ?? provider.useFactory.diDeps) {
      parameters.add(_getDependency(paramDep));
    }
    return FactoryProviderSource(
        provider.token, provider.useFactory, parameters);
  }

  ProviderSource _addClassProvider(
    CompileProviderMetadata provider,
    ProviderAstType providerType, {
    List<o.OutputType> typeArguments,
  }) {
    var paramDeps = provider.deps ?? provider.useClass.diDeps;
    // Resolve constructor parameters for class.
    var parameters = <ProviderSource>[];
    for (var paramDep in paramDeps) {
      parameters.add(_getDependency(paramDep));
    }
    return ClassProviderSource(
      provider.token,
      provider.useClass,
      parameters,
      typeArguments: typeArguments,
    );
  }

  ProviderSource _getLocalDependency(CompileTokenMetadata token) {
    return token != null ? _instances.get(token) : null;
  }

  ProviderSource _getDependency(CompileDiDependencyMetadata dep) {
    ProvidersNode currProviders = this;
    ProviderSource result;
    if (dep.isValue) {
      result = LiteralValueSource(dep.token, o.literal(dep.value));
    }
    if (result == null && !dep.isSkipSelf) {
      result = _getLocalDependency(dep.token);
    }
    // check parent elements
    while (result == null && currProviders._parent._parent != null) {
      currProviders = currProviders._parent;
      result = currProviders._getLocalDependency(dep.token);
    }
    // Ask host to build a ProviderSource that injects the instance
    // dynamically through injectorGet call.
    return _host.createDynamicInjectionSource(
        currProviders, result, dep.token, dep.isOptional);
  }

  /// Creates an expression that calls a functional directive.
  ProviderSource createFunctionalDirectiveSource(ProviderAst provider) {
    // Add functional directive invocation.
    // Get function parameter dependencies.
    final parameters = <ProviderSource>[];
    final mainProvider = provider.providers.first;
    for (var dep in mainProvider.deps) {
      parameters.add(_getDependency(dep));
    }
    return FunctionalDirectiveSource(
        mainProvider.token, mainProvider.useClass, parameters);
  }
}

/// Interface to be implemented by NodeProviders users.
abstract class ProvidersNodeHost {
  /// Creates an eager instance for a provider and returns reference to source.
  ProviderSource createProviderInstance(
      ProviderAst resolvedProvider,
      CompileDirectiveMetadata directiveMetadata,
      List<ProviderSource> providerValueExpressions,
      int uniqueId);

  /// Creates ProviderSource to call injectorGet on parent view that contains
  /// source NodeProviders.
  ProviderSource createDynamicInjectionSource(ProvidersNode source,
      ProviderSource value, CompileTokenMetadata token, bool optional);
}

class BuiltInSource extends ProviderSource {
  final o.Expression _value;

  BuiltInSource(CompileTokenMetadata token, this._value) : super(token);

  @override
  o.Expression build() => _value;

  @override
  final hasDynamicDependencies = false;
}

class LiteralValueSource extends ProviderSource {
  final o.Expression _value;

  LiteralValueSource(
    CompileTokenMetadata token,
    this._value, {
    this.hasDynamicDependencies = false,
  }) : super(token);

  @override
  o.Expression build() => _value;

  @override
  final bool hasDynamicDependencies;
}

bool _hasDynamicDependencies(Iterable<ProviderSource> sources) {
  for (final source in sources) {
    if (source is DynamicProviderSource || source.hasDynamicDependencies) {
      return true;
    }
  }
  return false;
}

class FactoryProviderSource extends ProviderSource {
  final CompileFactoryMetadata _factory;
  final List<ProviderSource> _parameters;

  FactoryProviderSource(
      CompileTokenMetadata token, this._factory, this._parameters)
      : super(token);

  @override
  o.Expression build() {
    List<o.Expression> paramExpressions = [];
    for (ProviderSource s in _parameters) paramExpressions.add(s.build());
    final create = o.importExpr(_factory).callFn(paramExpressions);
    if (hasDynamicDependencies) {
      return debugInjectorWrap(createDiTokenExpression(token), create);
    }
    return create;
  }

  @override
  bool get hasDynamicDependencies => _hasDynamicDependencies(_parameters);
}

class ClassProviderSource extends ProviderSource {
  final CompileTypeMetadata _classType;
  final List<ProviderSource> _parameters;
  final List<o.OutputType> _typeArguments;

  ClassProviderSource(
    CompileTokenMetadata token,
    this._classType,
    this._parameters, {
    List<o.OutputType> typeArguments,
  })  : _typeArguments = typeArguments,
        super(token);

  @override
  o.Expression build() {
    List<o.Expression> paramExpressions = [];
    for (ProviderSource s in _parameters) paramExpressions.add(s.build());
    final clazz = o.importExpr(_classType);
    final create = clazz.instantiate(
      paramExpressions,
      type: o.importType(_classType),
      genericTypes: _typeArguments,
    );
    if (hasDynamicDependencies) {
      return debugInjectorWrap(createDiTokenExpression(token), create);
    }
    return create;
  }

  @override
  bool get hasDynamicDependencies => _hasDynamicDependencies(_parameters);
}

class FunctionalDirectiveSource extends ProviderSource {
  final CompileTypeMetadata _classType;
  final List<ProviderSource> _parameters;

  FunctionalDirectiveSource(
      CompileTokenMetadata token, this._classType, this._parameters)
      : super(token);

  @override
  o.Expression build() {
    List<o.Expression> paramExpressions = [];
    for (ProviderSource s in _parameters) paramExpressions.add(s.build());
    return o.importExpr(_classType).callFn(paramExpressions);
  }

  @override
  bool get hasDynamicDependencies => _hasDynamicDependencies(_parameters);
}

/// Source for injectable values that are resolved by
/// dynamic lookup (injectorGet).
class DynamicProviderSource extends ProviderSource {
  final ProvidersNode parentProviders;
  final bool optional;
  final bool _isAppViewHost;

  DynamicProviderSource(this.parentProviders, CompileTokenMetadata token,
      this.optional, this._isAppViewHost)
      : super(token);

  @override
  o.Expression build() {
    o.Expression viewExpr =
        _isAppViewHost ? o.THIS_EXPR : o.ReadClassMemberExpr('parentView');
    var args = [
      createDiTokenExpression(token),
      o.ReadClassMemberExpr('viewData').prop('parentIndex')
    ];
    if (optional) {
      args.add(o.NULL_EXPR);
    }
    return viewExpr.callMethod('injectorGet', args);
  }

  @override
  final hasDynamicDependencies = false;
}
