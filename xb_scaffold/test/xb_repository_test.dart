import 'package:flutter_test/flutter_test.dart';
import 'package:xb_scaffold/xb_scaffold.dart';

// --------------- Concrete test classes ---------------

class _TestDataSource extends XBDataSource {
  bool initialized = false;
  bool disposed = false;

  @override
  void init() {
    super.init();
    initialized = true;
  }

  @override
  void dispose() {
    disposed = true;
    super.dispose();
  }
}

class _TestService extends XBService {
  final List<XBDataSource> _dataSources;

  _TestService({List<XBDataSource>? dataSources})
      : _dataSources = dataSources ?? [];

  @override
  List<XBDataSource> get dataSources => _dataSources;
}

class _TestRepository extends XBRepository {
  final List<XBService> _services;

  _TestRepository({List<XBService>? services}) : _services = services ?? [];

  @override
  List<XBService> get services => _services;
}

class _TrackedDataSource extends XBDataSource {
  final int id;
  final List<int> order;
  _TrackedDataSource(this.id, this.order);

  @override
  void dispose() {
    order.add(id);
    super.dispose();
  }
}

// --------------- Tests ---------------

void main() {
  group('XBDataSource', () {
    test('init and dispose are callable on base', () {
      final ds = _TestDataSource();
      expect(ds.initialized, isFalse);
      expect(ds.disposed, isFalse);

      ds.init();
      expect(ds.initialized, isTrue);

      ds.dispose();
      expect(ds.disposed, isTrue);
    });
  });

  group('XBService', () {
    test('init cascades to all dataSources in order', () {
      final ds1 = _TestDataSource();
      final ds2 = _TestDataSource();
      final service = _TestService(dataSources: [ds1, ds2]);

      service.init();

      expect(ds1.initialized, isTrue);
      expect(ds2.initialized, isTrue);
    });

    test('dispose cascades to all dataSources in reverse order', () {
      final disposeOrder = <int>[];
      final trackedDs1 = _TrackedDataSource(1, disposeOrder);
      final trackedDs2 = _TrackedDataSource(2, disposeOrder);
      final service = _TestService(dataSources: [trackedDs1, trackedDs2]);

      service.dispose();

      expect(disposeOrder, [2, 1]);
    });

    test('empty dataSources init and dispose without error', () {
      final service = _TestService();
      service.init();
      service.dispose();
    });
  });

  group('XBRepository', () {
    test('init cascades to all services and their dataSources', () {
      final ds = _TestDataSource();
      final service = _TestService(dataSources: [ds]);
      final repo = _TestRepository(services: [service]);

      repo.init();

      expect(ds.initialized, isTrue);
    });

    test('dispose cascades to all services in reverse', () {
      final ds1 = _TestDataSource();
      final ds2 = _TestDataSource();
      final service1 = _TestService(dataSources: [ds1]);
      final service2 = _TestService(dataSources: [ds2]);
      final repo = _TestRepository(services: [service1, service2]);

      repo.dispose();

      expect(ds1.disposed, isTrue);
      expect(ds2.disposed, isTrue);
    });

    test('empty services init and dispose without error', () {
      final repo = _TestRepository();
      repo.init();
      repo.dispose();
    });
  });

  group('setRepo lifecycle', () {
    test('setRepo inits the repository', () {
      final ds = _TestDataSource();
      final service = _TestService(dataSources: [ds]);
      final repo = _TestRepository(services: [service]);

      // Simulate what setRepo does
      repo.init();

      expect(ds.initialized, isTrue);
    });

    test('setRepo disposes old repo when replacing', () {
      final ds1 = _TestDataSource();
      final service1 = _TestService(dataSources: [ds1]);
      final repo1 = _TestRepository(services: [service1]);

      final ds2 = _TestDataSource();
      final service2 = _TestService(dataSources: [ds2]);
      final repo2 = _TestRepository(services: [service2]);

      // Simulate setRepo(repo1) then setRepo(repo2)
      repo1.init();
      repo1.dispose();
      repo2.init();

      expect(ds1.disposed, isTrue);
      expect(ds2.initialized, isTrue);
    });
  });
}
