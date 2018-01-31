import 'dart:async';

import 'package:angular/angular.dart';

/// A token representing the [ComponentFactory] to be loaded.
const runBenchmarkOn = const OpaqueToken('runBenchmarkOn');

/// A component interface that is able to run and reset a benchmark.
abstract class Benchmark {
  /// Start the benchmark.
  void start();

  /// Reset the benchmark (if applicable).
  void reset();
}

/// Setup and instrumentation to run a [Benchmark] component.
///
/// This component is expected to be loaded as the root component:
/// ```dart
/// void main() {
///   bootstrap(
///     BenchmarkComponent,
///     [provide(runBenchmarkOn, useValue: gen.SomeBenchmarkNgFactory)],
///     gen.initReflector,
///   );
/// }
/// ```
@Component(
  selector: 'benchmark',
  template: r'''
    <template #location></template>
    <button id="run" (click)="doStart()">Run</button>
    <button id="reset" (click)="doReset()">Reset</button>
  ''',
  // TODO(b/71710685): Change to `Visibility.local` to reduce code size.
  visibility: Visibility.all,
)
class BenchmarkComponent implements AfterViewInit {
  final ComponentLoader _loader;
  final ComponentFactory<Benchmark> _factory;

  Benchmark _component;

  @ViewChild('location', read: ViewContainerRef)
  ViewContainerRef location;

  BenchmarkComponent(this._loader, @Inject(runBenchmarkOn) this._factory);

  @override
  void ngAfterViewInit() {
    // Create the component in the next event loop.
    Timer.run(() {
      _component = _loader.loadNextToLocation(_factory, location).instance;
    });
  }

  void doStart() {
    _component.start();
  }

  void doReset() {
    _component.reset();
  }
}
