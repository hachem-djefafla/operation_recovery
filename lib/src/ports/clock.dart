/// Supplies wall-clock time without coupling domain logic to ambient time.
abstract interface class Clock {
  /// Returns the current time; the coordinator normalizes it to UTC.
  DateTime now();
}
