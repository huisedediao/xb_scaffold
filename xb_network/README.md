# xb_network

`xb_network` 是从 `xb_scaffold` 拆分出来的独立网络模块，基于 `dio`，提供统一初始化、请求封装、上传能力和请求/响应日志拦截。

## Features

- `XBDioConfig.init/reset` 全局网络配置
- `XBHttp.get/post/put/delete/request` 请求封装
- `XBHttp.fileUploadFromPath/fileUploadFromBytes` 上传封装
- `XBRequestInterceptor` / `XBResponseInterceptor` 默认日志拦截器
- 请求级附加拦截器（`inter`）

## Usage

```dart
import 'package:xb_network/xb_network.dart';

XBDioConfig.init(
  baseUrl: 'https://api.example.com',
  connectTimeout: 5,
  receiveTimeout: 5,
);

final users = await XBHttp.get<List<dynamic>>('/users');
```

## Testing

```bash
flutter test
```
