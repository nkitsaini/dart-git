import 'package:tuple/tuple.dart';

/// See https://github.com/michaelbull/kotlin-result
class Result<DataType> {
  DataType? data;

  Object? error;
  StackTrace? stackTrace;

  // ignore: prefer_initializing_formals
  Result(DataType data) : data = data;
  Result.fail(this.error, [StackTrace? stackTrace])
      : stackTrace = stackTrace ?? StackTrace.current {
    assert(error is Error || error is Exception);
  }

  Result._(this.data, this.error, this.stackTrace);

  /// Throws `ResultException`, use Result.unwind to get the true exception
  /// and stackTrace
  DataType getOrThrow() {
    assert(data != null || error != null);

    if (data != null) {
      return data!;
    } else {
      if (stackTrace != null) {
        throw ResultException(exception!, stackTrace!);
      }
      throw error!;
    }
  }

  /// Throws `ResultException`, use Result.unwind to get the true exception
  /// and stackTrace
  void throwOnError() {
    if (isFailure) {
      if (stackTrace != null) {
        throw ResultException(exception!, stackTrace!);
      }
      throw error!;
    }
  }

  bool get isFailure => error != null;
  bool get isSuccess => error == null;

  Exception? get exception {
    if (error == null) {
      return null;
    }
    if (error is Exception) {
      return error as Exception;
    }

    return Exception(error.toString());
  }

  static Tuple2<Exception, StackTrace> unwind(Object e, StackTrace st) {
    if (e is Error) e = Exception(e.toString());
    if (e is! ResultException) return Tuple2(e as Exception, st);

    var re = e;
    while (re.exception is ResultException) {
      re = re.exception as ResultException;
    }

    return Tuple2(re.exception, re.stackTrace);
  }
}

class ResultException implements Exception {
  final Exception exception;
  final StackTrace stackTrace;

  ResultException(this.exception, this.stackTrace);

  @override
  String toString() => exception.toString();
}

Future<Result<T>> catchAll<T>(Future<Result<T>> Function() catchFn) async {
  try {
    return await catchFn();
  } catch (e, st) {
    var t = Result.unwind(e, st);
    return Result.fail(t.item1, t.item2);
  }
}

Result<T> catchAllSync<T>(Result<T> Function() catchFn) {
  try {
    return catchFn();
  } catch (e, st) {
    var t = Result.unwind(e, st);
    return Result.fail(t.item1, t.item2);
  }
}

Result<Base> downcast<Base, Derived>(Result<Derived> other) {
  return Result._(other.data as Base?, other.error, other.stackTrace);
}

extension ResultFuture<T> on Future<Result<T>> {
  /// Convenience method to have to avoid putting parenthesis around the
  /// await expression
  Future<T> getOrThrow() async {
    var result = await this;
    return result.getOrThrow();
  }

  Future<void> throwOnError() async {
    var result = await this;
    result.throwOnError();
  }
}

Result<A> fail<A, B>(Result<B> result) {
  assert(result.error != null);
  return result.stackTrace != null
      ? Result<A>.fail(result.error!, result.stackTrace)
      : Result<A>.fail(result.error!, StackTrace.current);
}

/// Rust style try? operator.
Future<A> tryR<A>(Future<Result<A>> resultFuture) async {
  var result = await resultFuture;
  return result.getOrThrow();
}
