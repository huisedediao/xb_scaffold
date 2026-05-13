import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:xb_ume/xb_ume.dart';

void main() {
  final memoryStore = <String, dynamic>{
    'token': 'demo-token-should-be-masked',
    'featureA': true,
    'counter': 1,
  };

  XBUmeBinding.ensureInitialized(
    config: const XBUmeConfig(
      enable: kDebugMode,
      persistenceEnabled: true,
    ),
  );
  XBUme.registerStorageAdapter(
    XBUmeMapStorageAdapter(id: 'memory', data: memoryStore, allowWrite: true),
  );

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'xb_ume example',
      builder: XBUme.appBuilder(),
      navigatorObservers: [XBUme.routeObserver],
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF0A84FF)),
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final Dio _dio = Dio()
    ..interceptors.add(XBUmeDioInterceptor())
    ..options.connectTimeout = const Duration(seconds: 8)
    ..options.receiveTimeout = const Duration(seconds: 8);

  late final XBUmeHttpClient _httpClient = XBUmeHttpClient(http.Client());
  String _message = 'Ready';

  @override
  void dispose() {
    _httpClient.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('xb_ume Example')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              ElevatedButton(
                onPressed: () {
                  XBUme.log('hello from app log', tag: 'example');
                },
                child: const Text('Add Log'),
              ),
              ElevatedButton(
                onPressed: _requestByDio,
                child: const Text('Dio Request'),
              ),
              ElevatedButton(
                onPressed: _requestByHttp,
                child: const Text('Http Request'),
              ),
              ElevatedButton(
                onPressed: _requestFail,
                child: const Text('Fail Request'),
              ),
              ElevatedButton(
                onPressed: () {
                  Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      settings: const RouteSettings(name: '/detail'),
                      builder: (_) => const DetailPage(),
                    ),
                  );
                },
                child: const Text('Push Route'),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Text(_message),
          const SizedBox(height: 16),
          const Text(
            'Tap floating UME button to open panel.\n'
            'This demo covers M1-M4 modules.',
          ),
        ],
      ),
    );
  }

  Future<void> _requestByDio() async {
    try {
      final response = await _dio.get<Map<String, dynamic>>(
        'https://jsonplaceholder.typicode.com/todos/1',
        options: Options(headers: {'Authorization': 'Bearer-123'}),
      );
      setState(() {
        _message = 'Dio: ${jsonEncode(response.data)}';
      });
    } catch (e, s) {
      XBUme.log('dio error: $e',
          tag: 'dio', level: XBUmeLogLevel.error, stack: '$s');
    }
  }

  Future<void> _requestByHttp() async {
    try {
      final request = http.Request(
        'GET',
        Uri.parse('https://jsonplaceholder.typicode.com/posts/1'),
      );
      request.headers['token'] = 'secret-token';
      final response = await _httpClient.send(request);
      final text = await response.stream.bytesToString();
      setState(() {
        _message = 'Http: $text';
      });
    } catch (e, s) {
      XBUme.log('http error: $e',
          tag: 'http', level: XBUmeLogLevel.error, stack: '$s');
    }
  }

  Future<void> _requestFail() async {
    try {
      await _dio.get<dynamic>('https://invalid.xb-ume-domain-404.dev/test');
    } catch (e, s) {
      XBUme.log('expected fail: $e',
          tag: 'network', level: XBUmeLogLevel.warn, stack: '$s');
      setState(() {
        _message = 'Fail request captured';
      });
    }
  }
}

class DetailPage extends StatelessWidget {
  const DetailPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Detail')),
      body: Center(
        child: ElevatedButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Back'),
        ),
      ),
    );
  }
}
