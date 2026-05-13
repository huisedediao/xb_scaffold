import 'package:example/pages/xb_repository_demo_vm.dart';
import 'package:xb_scaffold/xb_scaffold.dart';
import 'package:flutter/material.dart';

class XBRepositoryDemo extends XBPage<XBRepositoryDemoVM> {
  const XBRepositoryDemo({super.key});

  @override
  generateVM(BuildContext context) {
    return XBRepositoryDemoVM(context: context);
  }

  @override
  Color? backgroundColor(BuildContext context) {
    return Colors.white;
  }

  @override
  Widget buildPage(BuildContext context) {
    final vm = vmOf(context);

    final controller = TextEditingController();

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: controller,
                  decoration: const InputDecoration(
                    hintText: 'Enter todo text...',
                    border: OutlineInputBorder(),
                  ),
                  onSubmitted: (text) {
                    vm.addTodo(text);
                    controller.clear();
                  },
                ),
              ),
              const SizedBox(width: 8),
              ElevatedButton(
                onPressed: () {
                  vm.addTodo(controller.text);
                  controller.clear();
                },
                child: const Text('Add'),
              ),
            ],
          ),
        ),
        if (vm.errorMessage != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              vm.errorMessage!,
              style: const TextStyle(color: Colors.red),
            ),
          ),
        Expanded(
          child: vm.isLoading
              ? const Center(child: CircularProgressIndicator())
              : ListView.builder(
                  itemCount: vm.todos.length,
                  itemBuilder: (context, index) {
                    final todo = vm.todos[index];
                    return ListTile(
                      title: Text(todo['text'] as String),
                      trailing: IconButton(
                        icon: const Icon(Icons.delete, color: Colors.red),
                        onPressed: () => vm.removeTodo(todo['id'] as int),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}
