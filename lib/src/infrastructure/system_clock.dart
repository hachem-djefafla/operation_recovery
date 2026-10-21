import '../ports/clock.dart';

/// The default UTC wall clock; it does not schedule or sleep.
final class SystemClock implements Clock {
  /// Creates a system wall-clock adapter.
  const SystemClock();

  @override
  DateTime now() => DateTime.now().toUtc();
}
