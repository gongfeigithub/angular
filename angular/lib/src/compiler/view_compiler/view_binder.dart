import 'package:meta/meta.dart';
import 'package:source_span/source_span.dart';
import 'package:angular/src/compiler/expression_parser/ast.dart' as ast;
import 'package:angular/src/compiler/output/output_ast.dart' as o;
import 'package:angular/src/compiler/parse_util.dart' show ParseErrorLevel;
import 'package:angular/src/compiler/schema/element_schema_registry.dart';
import 'package:angular/src/compiler/semantic_analysis/binding_converter.dart';
import 'package:angular/src/compiler/template_ast.dart';
import 'package:angular/src/compiler/template_parser.dart';
import 'package:angular/src/compiler/view_compiler/constants.dart';
import 'package:angular/src/core/linker/view_type.dart';
import 'package:angular_compiler/cli.dart' show logWarning, throwFailure;

import 'bound_value_converter.dart';
import 'compile_element.dart' show CompileElement;
import 'compile_method.dart' show CompileMethod;
import 'compile_view.dart' show CompileView;
import 'event_binder.dart'
    show
        bindRenderOutputs,
        collectEventListeners,
        CompileEventListener,
        bindDirectiveOutputs;
import 'ir/provider_source.dart';
import 'lifecycle_binder.dart'
    show
        bindDirectiveAfterContentLifecycleCallbacks,
        bindDirectiveAfterViewLifecycleCallbacks,
        bindDirectiveDestroyLifecycleCallbacks,
        bindPipeDestroyLifecycleCallbacks,
        bindDirectiveDetectChangesLifecycleCallbacks;
import 'property_binder.dart'
    show
        bindAndWriteToRenderer,
        bindDirectiveHostProps,
        bindDirectiveInputs,
        bindRenderInputs,
        bindRenderText;

/// Visits view nodes to generate code for bindings.
///
/// Called by ViewCompiler for each top level CompileView and the
/// ViewBinderVisitor recursively for each embedded template.
///
/// HostProperties are bound for Component and Host views, but not embedded
/// views.
void bindView(
  CompileView view,
  List<TemplateAst> parsedTemplate,
  ElementSchemaRegistry schemaRegistry, {
  @required bool bindHostProperties,
}) {
  var visitor = _ViewBinderVisitor(view);
  templateVisitAll(visitor, parsedTemplate);
  for (var pipe in view.pipes) {
    bindPipeDestroyLifecycleCallbacks(pipe.meta, pipe.instance, pipe.view);
  }

  if (bindHostProperties) {
    _bindViewHostProperties(view, schemaRegistry);
  }
}

class _ViewBinderVisitor implements TemplateAstVisitor<void, void> {
  final CompileView view;
  int _nodeIndex = 0;
  _ViewBinderVisitor(this.view);

  @override
  void visitBoundText(BoundTextAst ast, _) {
    var node = view.nodes[_nodeIndex++];
    if (node == null) {
      // The node was never added in ViewBuilder since it
      // is dead code.
      return;
    }
    bindRenderText(
        convertToBinding(ast, view.component.analyzedClass), node, view);
  }

  @override
  void visitText(TextAst ast, _) {
    _nodeIndex++;
  }

  @override
  void visitNgContainer(NgContainerAst ast, _) {
    templateVisitAll(this, ast.children);
  }

  @override
  void visitElement(ElementAst ast, _) {
    var compileElement = view.nodes[_nodeIndex++] as CompileElement;
    var listeners = collectEventListeners(ast.outputs, ast.directives,
        compileElement, view.component.analyzedClass);

    // Collect directive output names.
    final directiveOutputs = <String>{};
    for (var directiveAst in ast.directives) {
      directiveOutputs.addAll(directiveAst.directive.outputs.values);
    }

    // Determine which listeners must be registered as stream subscriptions,
    // and which must be registered as event handlers.
    final eventListeners = <CompileEventListener>[];
    final streamListeners = <CompileEventListener>[];
    for (var listener in listeners) {
      if (directiveOutputs.contains(listener.eventName)) {
        streamListeners.add(listener);
      } else {
        eventListeners.add(listener);
      }
    }

    bindRenderInputs(
      convertAllToBinding(ast.inputs,
          analyzedClass: view.component.analyzedClass),
      compileElement,
    );
    bindRenderOutputs(eventListeners);
    var index = -1;
    for (var directiveAst in ast.directives) {
      index++;
      ProviderSource s = compileElement.directiveInstances[index];
      // Skip functional directives.
      if (s == null) continue;
      var directiveInstance = s.build();
      if (directiveInstance == null) continue;
      var inputs = convertAllToBinding(directiveAst.inputs,
          directive: directiveAst.directive,
          analyzedClass: view.component.analyzedClass);
      bindDirectiveInputs(
          inputs, directiveAst.directive, directiveInstance, compileElement,
          isHostComponent: compileElement.view.viewType == ViewType.host);
      bindDirectiveDetectChangesLifecycleCallbacks(
          directiveAst, directiveInstance, compileElement);
      bindDirectiveHostProps(directiveAst, directiveInstance, compileElement);
      bindDirectiveOutputs(directiveAst, directiveInstance, streamListeners);
    }
    templateVisitAll(this, ast.children);
    // afterContent and afterView lifecycles need to be called bottom up
    // so that children are notified before parents
    index = -1;
    for (var directiveAst in ast.directives) {
      index++;
      ProviderSource s = compileElement.directiveInstances[index];
      // Skip functional directives.
      if (s == null) continue;
      var directiveInstance = s.build();
      if (directiveInstance == null) continue;
      bindDirectiveAfterContentLifecycleCallbacks(
          directiveAst.directive, directiveInstance, compileElement);
      bindDirectiveAfterViewLifecycleCallbacks(
          directiveAst.directive, directiveInstance, compileElement);
      bindDirectiveDestroyLifecycleCallbacks(
          directiveAst.directive, directiveInstance, compileElement);
    }
  }

  @override
  void visitEmbeddedTemplate(EmbeddedTemplateAst ast, _) {
    var compileElement = view.nodes[_nodeIndex++] as CompileElement;
    // The template parser ensures these listeners are for directive outputs,
    // so they all must be registered as stream subscriptions.
    var eventListeners = collectEventListeners(ast.outputs, ast.directives,
        compileElement, view.component.analyzedClass);
    var index = -1;
    for (var directiveAst in ast.directives) {
      index++;
      ProviderSource s = compileElement.directiveInstances[index];
      // Skip functional directives.
      if (s == null) continue;
      var directiveInstance = s.build();
      if (directiveInstance == null) continue;
      var inputs = convertAllToBinding(directiveAst.inputs,
          directive: directiveAst.directive,
          analyzedClass: view.component.analyzedClass);
      bindDirectiveInputs(
          inputs, directiveAst.directive, directiveInstance, compileElement);
      bindDirectiveDetectChangesLifecycleCallbacks(
          directiveAst, directiveInstance, compileElement);
      bindDirectiveOutputs(directiveAst, directiveInstance, eventListeners);
      bindDirectiveAfterContentLifecycleCallbacks(
          directiveAst.directive, directiveInstance, compileElement);
      bindDirectiveAfterViewLifecycleCallbacks(
          directiveAst.directive, directiveInstance, compileElement);
      bindDirectiveDestroyLifecycleCallbacks(
          directiveAst.directive, directiveInstance, compileElement);
    }
    bindView(compileElement.embeddedView, ast.children, null,
        bindHostProperties: false);
  }

  @override
  void visitI18nText(I18nTextAst ast, _) {
    _nodeIndex++;
  }

  @override
  void visitEvent(BoundEventAst ast, _) {}

  @override
  void visitNgContent(NgContentAst ast, _) {}

  @override
  void visitAttr(AttrAst ast, _) {}

  @override
  void visitDirective(DirectiveAst ast, _) {}

  @override
  void visitReference(ReferenceAst ast, _) {}

  @override
  void visitVariable(VariableAst ast, _) {}

  @override
  void visitDirectiveProperty(BoundDirectivePropertyAst ast, _) {}

  @override
  void visitElementProperty(BoundElementPropertyAst ast, _) {}

  @override
  void visitProvider(ProviderAst ast, _) {}
}

void _bindViewHostProperties(
    CompileView view, ElementSchemaRegistry schemaRegistry) {
  if (view.viewIndex != 0 || view.viewType != ViewType.component) return;
  var hostProps = view.component.hostProperties;
  if (hostProps == null) return;

  List<BoundElementPropertyAst> hostProperties = <BoundElementPropertyAst>[];

  var span = SourceSpan(SourceLocation(0), SourceLocation(0), '');
  hostProps.forEach((String propName, ast.AST expression) {
    var elementName = view.component.selector;
    hostProperties.add(createElementPropertyAst(elementName, propName,
        BoundExpression(expression), span, schemaRegistry, _handleError));
  });

  final method = CompileMethod();
  final compileElement = view.componentView.declarationElement;
  final renderNode = view.componentView.declarationElement.renderNode;
  final implicitReceiver = DetectChangesVars.cachedCtx;
  final converter = BoundValueConverter.forView(view, implicitReceiver);
  bindAndWriteToRenderer(
    convertAllToBinding(hostProperties,
        analyzedClass: view.component.analyzedClass),
    converter,
    o.THIS_EXPR,
    renderNode,
    compileElement.isHtmlElement,
    view.nameResolver,
    view.storage,
    method,
  );
  if (method.isNotEmpty) {
    view.detectHostChangesMethod = method;
  }
}

void _handleError(String message, SourceSpan sourceSpan,
    [ParseErrorLevel level]) {
  if (level == ParseErrorLevel.FATAL) {
    throwFailure(message);
  } else {
    logWarning(message);
  }
}
