import "package:meta/meta.dart";

import "../compile_metadata.dart" show CompileQueryMetadata, CompileTokenMap;
import "../identifiers.dart" show Identifiers;
import "../output/output_ast.dart" as o;
import "compile_element.dart" show CompileElement;
import "compile_view.dart" show CompileView;
import 'ir/provider_source.dart';
import 'ir/view_storage.dart';
import "view_compiler_utils.dart"
    show getPropertyInView, replaceReadClassMemberInExpression;

class _QueryValues {
  /// Compiled template associated to [values] and embedded [templates].
  final CompileView view;

  /// Values or embedded templates of the query.
  final valuesOrTemplates = <dynamic>[];

  _QueryValues(this.view);

  /// Whether there are nested embedded views in this instance.
  bool get hasNestedViews => valuesOrTemplates.any((v) => v is _QueryValues);
}

/// Compiles `@{Content|View}Child[ren]` to template IR.
///
/// Uses a conditional compilation strategy in order to deprecate `QueryList`:
/// https://github.com/dart-lang/angular/issues/688
abstract class CompileQuery {
  /// An expression that accesses the component's instance.
  ///
  /// In practice, this is almost always `this.ctx`.
  final ProviderSource _boundDirective;

  /// Extracted metadata information from the user-code.
  final CompileQueryMetadata metadata;

  /// Compiled view of the `@Component` that this query originated from.
  ///
  /// **NOTE**: A component whose template has `<template>` tags will have
  /// additional generated views (embedded views), which are expressed as part
  /// of [todoSomeProperty].
  final CompileView _queryRoot;

  /// A combination of direct expressions and nested templates needed.
  ///
  /// This is built-up during the lifetime of this class.
  final _QueryValues _values;

  factory CompileQuery({
    @required CompileQueryMetadata metadata,
    @required ViewStorage storage,
    @required CompileView queryRoot,
    @required ProviderSource boundDirective,
    @required int nodeIndex,
    @required int queryIndex,
  }) {
    return _ListCompileQuery(
      metadata,
      storage,
      queryRoot,
      boundDirective,
      nodeIndex: nodeIndex,
      queryIndex: queryIndex,
    );
  }

  factory CompileQuery.viewQuery({
    @required CompileQueryMetadata metadata,
    @required ViewStorage storage,
    @required CompileView queryRoot,
    @required ProviderSource boundDirective,
    @required int queryIndex,
  }) {
    return _ListCompileQuery(
      metadata,
      storage,
      queryRoot,
      boundDirective,
      nodeIndex: 1,
      queryIndex: queryIndex,
    );
  }

  CompileQuery._base(
    this.metadata,
    this._queryRoot,
    this._boundDirective,
  ) : _values = _QueryValues(_queryRoot);

  /// Whether the query is entirely static, i.e. there are no `<template>`s.
  bool get _isStatic => !_values.hasNestedViews;

  /// Whether the query is only setting a single value, not a list-like object.
  ///
  /// This aligns with `@QueryChild` and `@ContentChild`.
  // ignore: unused_element
  bool get _isSingle => metadata.first;

  /// Adds an expression [result] that originates from an [origin] view.
  ///
  /// The result of a given query is the sum of all invocations to this method.
  /// Some of the expressions are simple (i.e. reads from an existing class
  /// field) and others require proxy-ing through `mapNestedViews` in order to
  /// determine what `<template>`s are currently active.
  void addQueryResult(CompileView origin, o.Expression result) {
    // Determine if we have a path of embedded templates.
    final elementPath = _resolvePathToRoot(origin);
    var viewValues = _values;

    // If we do, then continue building QueryValues, a tree-like data structure.
    for (final element in elementPath) {
      final valuesOrTemplates = viewValues.valuesOrTemplates;
      final last = valuesOrTemplates.isNotEmpty ? valuesOrTemplates.last : null;
      if (last is _QueryValues && last.view == element.embeddedView) {
        viewValues = last;
      } else {
        assert(element.hasEmbeddedView);
        final newViewValues = _QueryValues(element.embeddedView);
        valuesOrTemplates.add(newViewValues);
        viewValues = newViewValues;
      }
    }

    // Add it to the applicable part of the view (either root or embedded).
    viewValues.valuesOrTemplates.add(result);

    // Finally, if this result doesn't come from the root, it means that some
    // change in an embedded view needs to invalidate the state of the previous
    // query.
    if (elementPath.isNotEmpty) {
      _setParentQueryAsDirty(origin);
    }
  }

  /// Returns the literal values of the list that the user-code receives.
  List<o.Expression> _buildQueryResult(
    _QueryValues viewValues, {
    bool recursive = false,
  }) {
    // Fast-path: There are no nested views, these are all static elements.
    if (!viewValues.hasNestedViews) {
      final result = <o.Expression>[];
      for (final expression in viewValues.valuesOrTemplates) {
        result.add(expression as o.Expression);
      }
      // In the recursive case (i.e. called by another mapNestedViews), we need
      // to return the results as a List<T> explicitly (this is a little complex
      // but lets further optimizations take place for the List<T> case).
      if (recursive) {
        return [o.literalArr(result)];
      }
      return result;
    }

    // At least a single node is a call to "mapNestedViews".
    return [
      _resultsWithNestedViews(viewValues.valuesOrTemplates, recursive),
    ];
  }

  o.Expression _resultsWithNestedViews(
    List<dynamic> valuesOrTemplates, [
    bool recursive = false,
  ]) {
    // The goal of this function is to always return a (non-recursive) List,
    // using the "flattenNodes" function where needed in order to conform to
    // the Dart type system.
    final expressions = <o.Expression>[];
    var isNestedViewsOnly = true;

    for (final valueOrTemplate in valuesOrTemplates) {
      if (valueOrTemplate is o.Expression) {
        expressions.add(o.literalArr([valueOrTemplate]));
        isNestedViewsOnly = false;
      } else if (valueOrTemplate is _QueryValues) {
        final invocation = _mapNestedViews(
          valueOrTemplate.view.declarationElement.appViewContainer,
          valueOrTemplate.view,
          _buildQueryResult(valueOrTemplate, recursive: true),
        );
        expressions.add(invocation);
      }
    }

    // Special case: Every node is a call to "mapNestedViews".
    //
    // If there is only a single node, compiles to:
    //   _appEl_0.mapNestedViews(...)
    //
    // ... instead of needing flattenNodes at all.
    if (isNestedViewsOnly && expressions.length == 1) {
      return expressions.first;
    }

    return _flattenNodes(o.literalArr(expressions));
  }

  /// Returns an expression that invokes `appElementN.mapNestedViews`.
  ///
  /// This is required to traverse embedded `<template>` views for query matches.
  o.Expression _mapNestedViews(
    o.Expression appElementN,
    CompileView view,
    List<o.Expression> expressions,
  ) {
    // Should return:
    //
    //   appElementN.mapNestedViews(({view.Type} nestedView) {
    //     return /* {expressions} that is List<T> */
    //   });

    // Changes `_el_0` to `nestedView._el_0`.
    final adjustedExpressions = expressions.map((expr) {
      return replaceReadClassMemberInExpression(
        expr,
        (_) => o.variable('nestedView'),
      );
    }).toList();

    // Invokes `appElementN.mapNestedView`.
    return appElementN.callMethod('mapNestedViews', [
      o.fn(
        [o.FnParam('nestedView', view.classType)],
        [o.ReturnStatement(o.literalVargs(adjustedExpressions))],
      ),
    ]);
  }

  /// Invoked by [addQueryResult] when the [_queryRoot] is now dirty.
  ///
  /// This means during the next change detection cycle we need to rebuild the
  /// result of the query and invoke the bound setter or field accessor.
  void _setParentQueryAsDirty(CompileView origin);

  /// Returns the path required to traverse back to the [_queryRoot].
  ///
  /// This information is used to build up the [_QueryValues] required to
  /// express and retrieve the contents of the query at runtime.
  ///
  /// * For a simple query of static elements in a template, this is `[]`.
  /// * For a more complex query with embedded `<template>`s, this will be
  ///   the path to that embedded template. So for example, this might be a
  ///   single `[ViewComponent0]` when nested in a single `<template>` and a
  ///   longer `[ViewComponent0, ViewComponent1]` when nested even deeper.
  List<CompileElement> _resolvePathToRoot(CompileView view) {
    if (view == _queryRoot) {
      return const [];
    }
    final pathToRoot = <CompileElement>[];
    var currentView = view;
    while (currentView != null && currentView != _queryRoot) {
      final parentElement = currentView.declarationElement;
      pathToRoot.insert(0, parentElement);
      currentView = parentElement.view;
    }
    return pathToRoot;
  }

  /// Return code that will set the query contents at change-detection time.
  ///
  /// This is the general case, where the value of the query is not known at
  /// compile time (changes as embedded `<template>`s are created or destroyed)
  /// or we want to have more predictable timing of the setter being invoked.
  List<o.Statement> createDynamicUpdates();

  /// Return code that will immediately set the query contents at build-time.
  ///
  /// This is an optimization over [createDynamicUpdates] and requires that:
  /// * The query origin is `@ViewChild` or `@ContentChild` (single item).
  /// * No part of the query could be inside of a `<template>` (embedded).
  ///
  /// In practice, most queries are compiled through [createDynamicUpdates], In
  /// the future it will be possible to optimize further and use this method for
  /// more query types.
  List<o.Statement> createImmediateUpdates();
}

class _ListCompileQuery extends CompileQuery {
  final ViewStorage _storage;
  final int _nodeIndex;
  final int _queryIndex;

  _ListCompileQuery(
    CompileQueryMetadata metadata,
    this._storage,
    CompileView queryRoot,
    ProviderSource boundDirective, {
    @required int nodeIndex,
    @required int queryIndex,
  })  : _nodeIndex = nodeIndex,
        _queryIndex = queryIndex,
        super._base(metadata, queryRoot, boundDirective);

  ViewStorageItem _dirtyFieldIfNeeded;

  ViewStorageItem get _dirtyField {
    return _dirtyFieldIfNeeded ??= _createQueryDirtyField(
      metadata: metadata,
      storage: _storage,
      nodeIndex: _nodeIndex,
      queryIndex: _queryIndex,
    );
  }

  /// Inserts a `bool {property}` field in the generated view.
  ///
  /// Returns an expression pointing to that field.
  static ViewStorageItem _createQueryDirtyField({
    @required CompileQueryMetadata metadata,
    @required ViewStorage storage,
    @required int nodeIndex,
    @required int queryIndex,
  }) {
    final selector = metadata.selectors.first.name;
    // This is to avoid churn in the golden files/output while debugging.
    //
    // We can rename the properties after we decide to keep this code branch.
    String property;
    if (nodeIndex == -1) {
      // @ViewChild[ren].
      property = '_viewQuery_${selector}_${queryIndex}_isDirty';
    } else {
      // @ContentChild[ren].
      property = '_query_${selector}_${nodeIndex}_${queryIndex}_isDirty';
    }
    // bool _query_foo_0_0_isDirty = true;
    return storage.allocate(
      property,
      outputType: o.BOOL_TYPE,
      modifiers: [o.StmtModifier.Private],
      initializer: o.literal(true),
    );
  }

  @override
  void _setParentQueryAsDirty(CompileView origin) {
    // We do not need a dirty field for queries that never change.
    if (_isStatic) {
      return;
    }
    final queryDirtyField = getPropertyInView(
      _storage.buildReadExpr(_dirtyField),
      origin,
      _queryRoot,
    ) as o.ReadPropExpr;
    origin.dirtyParentQueriesMethod.addStmt(
      queryDirtyField.set(o.literal(true)).toStmt(),
    );
  }

  @override
  List<o.Statement> createDynamicUpdates() {
    if (_isStatic) {
      return const [];
    }
    final statements = <o.Statement>[]
      ..addAll(_createUpdates())
      ..add(_storage.buildWriteExpr(_dirtyField, o.literal(false)).toStmt());
    return [
      o.IfStmt(
        _storage.buildReadExpr(_dirtyField),
        statements,
      ),
    ];
  }

  @override
  List<o.Statement> createImmediateUpdates() {
    return _isStatic ? _createUpdates() : const [];
  }

  List<o.Statement> _createUpdates() {
    final queryValueExpressions = _buildQueryResult(_values);
    o.Expression result;

    if (_values.hasNestedViews) {
      if (queryValueExpressions.length == 1) {
        result = _createsUpdatesSingleNested(queryValueExpressions);
      } else {
        result = _createUpdatesMultiNested(queryValueExpressions);
      }
    } else {
      // Optimization: Avoid .singleChild = null.
      //
      // Otherwise in build() we would write:
      //   build() {
      //     context.childField = null;
      //   }
      //
      // ... which should be skip-able in the following condition:
      if (_isSingle && queryValueExpressions.isEmpty) {
        return const [];
      }
      result = _createUpdatesStaticOnly(queryValueExpressions);
    }
    return [
      _boundDirective.build().prop(metadata.propertyName).set(result).toStmt()
    ];
  }

  // Only static elements are the result of the query.
  //
  // * If this is for @{Content|View}Child, use the first value.
  // * Else, return the element(s) as a List.
  o.Expression _createUpdatesStaticOnly(List<o.Expression> values) => _isSingle
      ? values.isEmpty ? o.NULL_EXPR : values.first
      : o.literalArr(values);

  // Returns the equivalent of `{list}.isNotEmpty ? {list}.first : null`.
  static o.Expression _firstIfNotEmpty(o.Expression list) {
    // Optimization: .isNotEmpty will *always* == true.
    if (list is o.LiteralArrayExpr && list.entries.isNotEmpty) {
      return list.prop('first');
    }
    // Base case: Check .isNotEmpty before calling .first.
    //
    // Note that the list expression could itself be a `.mapNestedValues`, so
    // we use an external utility function to guarantee that we don't create
    // this expression twice.
    return _firstOrNull(list);
  }

  // A single call to "mapNestedViews" is the result of this query.
  //
  // * If this is for @{Content|View}Child, use {expression}.first.
  // * Else, just return the {expression} itself (already a List).
  o.Expression _createsUpdatesSingleNested(List<o.Expression> values) {
    final first = values.first;
    return _isSingle ? _firstIfNotEmpty(first) : first;
  }

  // Multiple elements, where at least one is "mapNestedViews".
  //
  // Here is where it gets a little more complicated; we need to always return
  // a List<T> ultimately. We have an option of returning a List<List<T>> and
  // using "flattenNodes" to turn it into a List<T>, but we can't be any more
  // recursive than that with the Dart type system.
  //
  // So:
  //   * flattenNodes([ mapNestedViews, mapNestedViews ]) OR
  //   * flattenNodes([ mapNestedViews, [staticElement] ])
  //
  // .. is OK.
  o.Expression _createUpdatesMultiNested(List<o.Expression> values) {
    final result = _flattenNodes(o.literalArr(values));
    return _isSingle ? _firstIfNotEmpty(result) : result;
  }
}

void addQueryToTokenMap(
  CompileTokenMap<List<CompileQuery>> map,
  CompileQuery query,
) {
  for (final selector in query.metadata.selectors) {
    var entry = map.get(selector);
    if (entry == null) {
      entry = [];
      map.add(selector, entry);
    }
    entry.add(query);
  }
}

final _flattenNodesFn = o.importExpr(Identifiers.flattenNodes);
final _firstOrNullFn = o.importExpr(Identifiers.firstOrNull);

/// Flattens a `List<List<?>>` into a `List<?>`.
o.Expression _flattenNodes(o.Expression nodeExpressions) =>
    _flattenNodesFn.callFn([nodeExpressions]);

/// Returns `listExpression.isNotEmpty ? listExpression.first : null`.
o.Expression _firstOrNull(o.Expression listExpression) =>
    _firstOrNullFn.callFn([listExpression]);
