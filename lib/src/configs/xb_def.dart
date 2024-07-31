/// value getter
/// ============================================================================
typedef XBValueGetter<T, S> = T Function(S value);

typedef XBValueGetter2<T, S, O> = T Function(S value1, O value2);

typedef XBValueGetter3<T, S, O, P> = T Function(S value1, O value2, P value3);

typedef XBValueGetter4<T, S, O, P, W> = T Function(
    S value1, O value2, P value3, W value4);

typedef XBValueGetter5<T, S, O, P, W, Z> = T Function(
    S value1, O value2, P value3, W value4, Z value5);

/// value changed
/// ============================================================================
typedef XBValueChanged2<T, S> = void Function(T value1, S value2);

typedef XBValueChanged3<T, S, O> = void Function(T value1, S value2, O value3);

typedef XBValueChanged4<T, S, O, P> = void Function(
    T value1, S value2, O value3, P value4);

typedef XBValueChanged5<T, S, O, P, W> = void Function(
    T value1, S value2, O value3, P value4, W value5);
