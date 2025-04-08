import 'package:flutter/material.dart';
import 'package:xb_scaffold/xb_scaffold.dart';

class DrawerDemo extends XBPage<DrawerDemoVM> {
  const DrawerDemo({super.key});

  @override
  DrawerDemoVM generateVM(BuildContext context) {
    return DrawerDemoVM(context: context);
  }

  @override
  Widget buildPage(DrawerDemoVM vm, BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('侧边菜单示例'),
        actions: [
          // 添加右侧菜单按钮
          IconButton(
            icon: const Icon(Icons.menu),
            onPressed: () {
              Scaffold.of(context).openEndDrawer();
            },
          ),
        ],
      ),
      // 左侧菜单
      drawer: Drawer(
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            const DrawerHeader(
              decoration: BoxDecoration(
                color: Colors.blue,
              ),
              child: Center(
                child: Text(
                  '左侧菜单',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 24,
                  ),
                ),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.home),
              title: const Text('首页'),
              onTap: () {
                Navigator.pop(context);
              },
            ),
            ListTile(
              leading: const Icon(Icons.settings),
              title: const Text('设置'),
              onTap: () {
                Navigator.pop(context);
              },
            ),
            ListTile(
              leading: const Icon(Icons.info),
              title: const Text('关于'),
              onTap: () {
                Navigator.pop(context);
              },
            ),
          ],
        ),
      ),
      // 右侧菜单
      endDrawer: Drawer(
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            const DrawerHeader(
              decoration: BoxDecoration(
                color: Colors.green,
              ),
              child: Center(
                child: Text(
                  '右侧菜单',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 24,
                  ),
                ),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.person),
              title: const Text('个人中心'),
              onTap: () {
                Navigator.pop(context);
              },
            ),
            ListTile(
              leading: const Icon(Icons.notifications),
              title: const Text('消息通知'),
              onTap: () {
                Navigator.pop(context);
              },
            ),
            ListTile(
              leading: const Icon(Icons.help),
              title: const Text('帮助'),
              onTap: () {
                Navigator.pop(context);
              },
            ),
          ],
        ),
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            ElevatedButton(
              onPressed: () {
                Scaffold.of(context).openDrawer();
              },
              child: const Text('打开左侧菜单'),
            ),
            const SizedBox(height: 20),
            ElevatedButton(
              onPressed: () {
                Scaffold.of(context).openEndDrawer();
              },
              child: const Text('打开右侧菜单'),
            ),
          ],
        ),
      ),
    );
  }
}

class DrawerDemoVM extends XBPageVM<DrawerDemo> {
  DrawerDemoVM({required super.context});
}
