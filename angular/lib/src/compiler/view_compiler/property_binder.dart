import 'package:angular/src/compiler/compile_metadata.dart';
import 'package:angular/src/compiler/identifiers.dart' show Identifiers;
import 'package:angular/src/compiler/ir/model.dart' as ir;
import 'package:angular/src/compiler/output/output_ast.dart' as o;
import 'package:angular/src/compiler/template_ast.dart' show DirectiveAst;
import 'package:angular/src/core/change_detection/constants.dart'
    show ChangeDetectionStrategy;
import 'package:angular/src/core/metadata/lifecycle_hooks.dart'
    show LifecycleHooks;

import 'bound_value_converter.dart';
import 'compile_element.dart' show CompileElement, CompileNode;
import 'compile_method.dart' show CompileMethod;
import 'compile_view.dart' show CompileView, NodeReference;
import 'constants.dart' show DetectChangesVars;
import 'ir/view_storage.dart';
import 'update_statement_visitor.dart' show bindingToUpdateStatement;
import 'view_compiler_utils.dart' show unwrapDirective, unwrapDirectiveInstance;
import 'view_name_resolver.dart';

/// For each binding, creates code to update the binding.
///
/// Example:
///     final currVal_1 = this.context.someBoolValue;
///     if (import6.checkBinding(this._expr_1,currVal_1)) {
///       this.renderer.setElementClass(this._el_4,'disabled',currVal_1);
///       this._expr_1 = currVal_1;
///     }
void bindAndWriteToRenderer(
  List<ir.Binding> bindings,
  BoundValueConverter converter,
  o.Expression appViewInstance,
  NodeReference renderNode,
  bool isHtmlElement,
  ViewNameResolver nameResolver,
  ViewStorage storage,
  CompileMethod targetMethod, {
  bool isHostComponent = false,
  bool calcChanged = false,
}) {
  final dynamicMethod = CompileMethod();
  final constantMethod = CompileMethod();
  for (var binding in bindings) {
    if (binding.isDirect) {
      _directBinding(
        binding,
        converter,
        binding.source.isImmutable ? constantMethod : dynamicMethod,
        appViewInstance,
        renderNode,
        isHtmlElement,
      );
      continue;
    }
    _checkBinding(
        binding,
        converter,
        nameResolver,
        appViewInstance,
        renderNode,
        isHtmlElement,
        calcChanged,
        storage,
        dynamicMethod,
        constantMethod,
        isHostComponent);
  }
  if (constantMethod.isNotEmpty) {
    targetMethod.addStmtsIfFirstCheck(constantMethod.finish());
  }
  if (dynamicMethod.isNotEmpty) {
    targetMethod.addStmts(dynamicMethod.finish());
  }
}

void bindRenderText(
    ir.Binding binding, CompileNode compileNode, CompileView view) {
  if (binding.source.isImmutable) {
    // We already set the value to the text node at creation
    return;
  }
  _directBinding(
    binding,
    BoundValueConverter.forView(view, DetectChangesVars.cachedCtx),
    view.detectChangesRenderPropertiesMethod,
    o.THIS_EXPR,
    compileNode.renderNode,
    false,
  );
}

void bindRenderInputs(
    List<ir.Binding> bindings, CompileElement compileElement) {
  var appViewInstance = compileElement.component == null
      ? o.THIS_EXPR
      : compileElement.componentView;
  var renderNode = compileElement.renderNode;
  var view = compileElement.view;
  var implicitReceiver = DetectChangesVars.cachedCtx;
  var converter = BoundValueConverter.forView(view, implicitReceiver);
  bindAndWriteToRenderer(
    bindings,
    converter,
    appViewInstance,
    renderNode,
    compileElement.isHtmlElement,
    view.nameResolver,
    view.storage,
    view.detectChangesRenderPropertiesMethod,
  );
}

void bindDirectiveInputs(
    List<ir.Binding> inputs,
    CompileDirectiveMetadata directive,
    o.Expression directiveInstance,
    CompileElement compileElement,
    {bool isHostComponent = false}) {
  if (directive.inputs.isEmpty) {
    return;
  }

  var view = compileElement.view;
  var detectChangesInInputsMethod = view.detectChangesInInputsMethod;
  var lifecycleHooks = directive.lifecycleHooks;
  bool afterChanges = lifecycleHooks.contains(LifecycleHooks.afterChanges);
  var isOnPushComp = directive.isComponent &&
      directive.changeDetection == ChangeDetectionStrategy.OnPush;
  var calcChanged = isOnPushComp || afterChanges;

  if (afterChanges) {
    view.requiresAfterChangesCall = true;
  }

  // We want to call AfterChanges lifecycle only if we detect a change,
  // unlike OnChanges, we don't need to collect a map of SimpleChange(s)
  // therefore we keep track of changes using bool changed variable.
  // At the beginning of change detecting inputs we reset this flag to false,
  // and then set it to true if any of it's inputs change.
  if (calcChanged && !isHostComponent) {
    detectChangesInInputsMethod
        .addStmt(DetectChangesVars.changed.set(o.literal(false)).toStmt());
  }
  bindAndWriteToRenderer(
    inputs,
    BoundValueConverter.forView(view, DetectChangesVars.cachedCtx),
    directiveInstance,
    null,
    false,
    view.nameResolver,
    view.storage,
    detectChangesInInputsMethod,
    isHostComponent: isHostComponent,
    calcChanged: calcChanged,
  );
  if (isOnPushComp) {
    detectChangesInInputsMethod.addStmt(o.IfStmt(DetectChangesVars.changed, [
      compileElement.componentView.callMethod('markAsCheckOnce', []).toStmt()
    ]));
  }
}

void _directBinding(
  ir.Binding binding,
  BoundValueConverter converter,
  CompileMethod method,
  o.Expression appViewInstance,
  NodeReference renderNode,
  bool isHtmlElement,
) {
  var expression =
      converter.convertSourceToExpression(binding.source, binding.target.type);
  var updateStatement = bindingToUpdateStatement(
    binding,
    appViewInstance,
    renderNode,
    isHtmlElement,
    expression,
  );
  method.addStmt(updateStatement);
}

/// For the given binding, creates code to update the binding.
///
/// Example:
///     final currVal_1 = this.context.someBoolValue;
///     if (import6.checkBinding(this._expr_1,currVal_1)) {
///       this.renderer.setElementClass(this._el_4,'disabled',currVal_1);
///       this._expr_1 = currVal_1;
///     }
void _checkBinding(
    ir.Binding binding,
    BoundValueConverter converter,
    ViewNameResolver nameResolver,
    o.Expression appViewInstance,
    NodeReference renderNode,
    bool isHtmlElement,
    bool calcChanged,
    ViewStorage storage,
    CompileMethod dynamicMethod,
    CompileMethod constantMethod,
    bool isHostComponent) {
  // Add to view bindings collection.
  int bindingIndex = nameResolver.createUniqueBindIndex();

  // Expression that points to _expr_## stored value.
  var fieldExpr = _createBindFieldExpr(bindingIndex);

  // Expression for current value of expression when value is re-read.
  var currValExpr = _createCurrValueExpr(bindingIndex);

  var updateStmts = <o.Statement>[
    bindingToUpdateStatement(
      binding,
      appViewInstance,
      renderNode,
      isHtmlElement,
      currValExpr,
    )
  ];

  if (calcChanged) {
    updateStmts.add(DetectChangesVars.changed.set(o.literal(true)).toStmt());
  }

  final checkExpression =
      converter.convertSourceToExpression(binding.source, binding.target.type);
  _bind(
    storage,
    currValExpr,
    fieldExpr,
    checkExpression,
    binding.source.isImmutable,
    binding.source.isNullable,
    updateStmts,
    dynamicMethod,
    constantMethod,
    fieldType: binding.target.type,
    isHostComponent: isHostComponent,
  );
}

o.ReadClassMemberExpr _createBindFieldExpr(num exprIndex) =>
    o.ReadClassMemberExpr('_expr_$exprIndex');

o.ReadVarExpr _createCurrValueExpr(num exprIndex) =>
    o.variable('currVal_$exprIndex');

/// Generates code to bind template expression.
///
/// If [checkExpression] is immutable, code is added to [literalMethod] to be
/// executed once when the component is created. Otherwise statements are added
/// to [method] to be executed on each change detection cycle.
void _bind(
  ViewStorage storage,
  o.ReadVarExpr currValExpr,
  o.ReadClassMemberExpr fieldExpr,
  o.Expression checkExpression,
  bool isImmutable,
  bool isNullable,
  List<o.Statement> actions,
  CompileMethod method,
  CompileMethod literalMethod, {
  o.OutputType fieldType,
  bool isHostComponent = false,
  o.Expression fieldExprInitializer,
}) {
  if (isImmutable) {
    // If the expression is immutable, it will never change, so we can run it
    // once on the first change detection.
    if (!isHostComponent) {
      _bindLiteral(checkExpression, actions, currValExpr.name, fieldExpr.name,
          literalMethod, isNullable);
    }
    return;
  }
  if (checkExpression == null) {
    // e.g. an empty expression was given
    return;
  }
  bool isPrimitive = _isPrimitiveFieldType(fieldType);
  ViewStorageItem previousValueField = storage.allocate(fieldExpr.name,
      modifiers: const [o.StmtModifier.Private],
      initializer: fieldExprInitializer,
      outputType: isPrimitive ? fieldType : null);
  method.addStmt(currValExpr
      .set(checkExpression)
      .toDeclStmt(null, [o.StmtModifier.Final]));
  method.addStmt(o.IfStmt(
      o.importExpr(Identifiers.checkBinding).callFn([fieldExpr, currValExpr]),
      List.from(actions)
        ..addAll([
          storage.buildWriteExpr(previousValueField, currValExpr).toStmt()
        ])));
}

/// The same as [_bind], but we know that [checkExpression] is a literal.
///
/// This means we don't need to create a change detection field or check if it
/// has changed. We know for sure that there will only be one transition from
/// [null] to whatever the value of [checkExpression] is. So we can just output
/// the [actions] and run them once on the first change detection run.
// TODO(alorenzen): Replace usages with _directBinding().
void _bindLiteral(
    o.Expression checkExpression,
    List<o.Statement> actions,
    String currValName,
    String fieldName,
    CompileMethod method,
    bool isNullable) {
  if (checkExpression == o.NULL_EXPR ||
      (checkExpression is o.LiteralExpr && checkExpression.value == null)) {
    // In this case, there is no transition, since change detection variables
    // are initialized to null.
    return;
  }

  var mappedActions = actions
      // Replace all 'currVal_X' with the actual expression
      .map(
          (stmt) => o.replaceVarInStatement(currValName, checkExpression, stmt))
      // Replace all 'expr_X' with 'null'
      .map((stmt) => o.replaceVarInStatement(fieldName, o.NULL_EXPR, stmt));
  if (isNullable) {
    method.addStmt(o.IfStmt(
        checkExpression.notIdentical(o.NULL_EXPR), mappedActions.toList()));
  } else {
    method.addStmts(mappedActions.toList());
  }
}

// Component or directive level host properties are change detected inside
// the component itself inside detectHostChanges method, no need to
// generate code at call-site.
void bindDirectiveHostProps(DirectiveAst directiveAst,
    o.Expression directiveInstance, CompileElement compileElement) {
  if (!directiveAst.hasHostProperties) return;
  var directive = directiveAst.directive;
  o.Expression callDetectHostPropertiesExpr;
  if (directive.isComponent) {
    final target = compileElement.componentView;
    callDetectHostPropertiesExpr =
        target.callMethod('detectHostChanges', [DetectChangesVars.firstCheck]);
  } else {
    if (unwrapDirectiveInstance(directiveInstance) == null) return;
    final target = unwrapDirective(directiveInstance);
    callDetectHostPropertiesExpr = target.callMethod('detectHostChanges', [
      compileElement.component != null
          ? compileElement.componentView
          : o.THIS_EXPR,
      compileElement.renderNode.toReadExpr()
    ]);
  }
  compileElement.view.detectChangesRenderPropertiesMethod
      .addStmt(callDetectHostPropertiesExpr.toStmt());
}

bool _isPrimitiveFieldType(o.OutputType type) {
  if (type == o.BOOL_TYPE ||
      type == o.INT_TYPE ||
      type == o.DOUBLE_TYPE ||
      type == o.NUMBER_TYPE ||
      type == o.STRING_TYPE) return true;
  if (type is o.ExternalType) {
    String name = type.value.name;
    return isPrimitiveTypeName(name.trim());
  }
  return false;
}

bool isPrimitiveTypeName(String typeName) {
  switch (typeName) {
    case 'bool':
    case 'int':
    case 'num':
    case 'double':
    case 'String':
      return true;
  }
  return false;
}
