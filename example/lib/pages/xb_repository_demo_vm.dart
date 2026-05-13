import 'package:example/pages/xb_repository_demo.dart';
import 'package:xb_scaffold/xb_scaffold.dart';

// --------------- DataSource ---------------
class _TodoLocalDataSource extends XBDataSource {
  final List<Map<String, dynamic>> _items = [];
  int _nextId = 1;

  List<Map<String, dynamic>> getAll() => List.unmodifiable(_items);

  Map<String, dynamic> add(String text) {
    final item = {'id': _nextId++, 'text': text.trim(), 'done': false};
    _items.add(item);
    return item;
  }

  bool remove(int id) {
    final len = _items.length;
    _items.removeWhere((e) => e['id'] == id);
    return _items.length < len;
  }
}

// --------------- Service ---------------
class _TodoService extends XBService {
  final _TodoLocalDataSource _localDs = _TodoLocalDataSource();

  @override
  List<XBDataSource> get dataSources => [_localDs];

  List<Map<String, dynamic>> fetchTodos() => _localDs.getAll();

  String? validateAndAdd(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return 'Text cannot be empty';
    _localDs.add(trimmed);
    return null;
  }

  bool removeTodo(int id) => _localDs.remove(id);
}

// --------------- Repository ---------------
class _TodoRepository extends XBRepository {
  final _TodoService _todoService = _TodoService();

  @override
  List<XBService> get services => [_todoService];

  List<Map<String, dynamic>>? _cachedTodos;

  List<Map<String, dynamic>> getTodos() {
    _cachedTodos ??= _todoService.fetchTodos();
    return _cachedTodos!;
  }

  String? addTodo(String text) {
    _cachedTodos = null;
    return _todoService.validateAndAdd(text);
  }

  bool removeTodo(int id) {
    _cachedTodos = null;
    return _todoService.removeTodo(id);
  }
}

// --------------- VM ---------------
class XBRepositoryDemoVM extends XBPageVM<XBRepositoryDemo> {
  XBRepositoryDemoVM({required super.context});

  List<Map<String, dynamic>> todos = [];
  String? errorMessage;
  bool isLoading = true;

  _TodoRepository get _todoRepo => repo<_TodoRepository>()!;

  @override
  void didCreated() {
    setRepo(_TodoRepository());
    super.didCreated();
    loadTodos();
  }

  void loadTodos() {
    isLoading = true;
    errorMessage = null;
    notify();

    Future.delayed(const Duration(milliseconds: 300), () {
      if (disposed) return;
      todos = _todoRepo.getTodos();
      isLoading = false;
      notify();
    });
  }

  void addTodo(String text) {
    final error = _todoRepo.addTodo(text);
    if (error != null) {
      errorMessage = error;
    } else {
      errorMessage = null;
      todos = _todoRepo.getTodos();
    }
    notify();
  }

  void removeTodo(int id) {
    _todoRepo.removeTodo(id);
    todos = _todoRepo.getTodos();
    notify();
  }
}
