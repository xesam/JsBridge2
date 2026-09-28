import 'package:flutter/material.dart';
import 'package:js_bridge_core/js_bridge_core.dart';

class PickInputScreen extends StatefulWidget {
  const PickInputScreen({super.key});

  @override
  State<PickInputScreen> createState() => _PickInputScreenState();
}

class _PickInputScreenState extends State<PickInputScreen> {
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _ageController = TextEditingController();

  @override
  void dispose() {
    _nameController.dispose();
    _ageController.dispose();
    super.dispose();
  }

  void _submit() {
    final String name = _nameController.text.trim();
    final int? age = int.tryParse(_ageController.text.trim());

    if (name.isEmpty) {
      Navigator.of(context).pop(
        const BridgeHandlerResult.failure(
          BridgeError(
            code: 'E_INVALID_PAYLOAD',
            message: 'name is required',
          ),
        ),
      );
      return;
    }

    if (age == null || age < 0) {
      Navigator.of(context).pop(
        const BridgeHandlerResult.failure(
          BridgeError(
            code: 'E_INVALID_PAYLOAD',
            message: 'age must be a non-negative integer',
          ),
        ),
      );
      return;
    }

    Navigator.of(context).pop(
      BridgeHandlerResult.success(<String, dynamic>{
        'name': name,
        'age': age,
        'native': true,
      }),
    );
  }

  void _cancel() {
    Navigator.of(context).pop(
      const BridgeHandlerResult.failure(
        BridgeError(code: 'E_INTERNAL', message: 'launch canceled'),  // 返回 E_INTERNAL 而非 E_CANCELED——E_CANCELED 为 JS 本地码，不跨端传输（docs/03 §8）
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Pick Input'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: _cancel,
        ),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            TextField(
              controller: _nameController,
              decoration: const InputDecoration(
                labelText: 'name',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _ageController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'age',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _submit,
              child: const Text('Submit'),
            ),
          ],
        ),
      ),
    );
  }
}
