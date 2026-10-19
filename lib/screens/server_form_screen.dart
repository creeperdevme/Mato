import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/server_profile.dart';
import '../services/server_store.dart';

class ServerFormScreen extends StatefulWidget {
  const ServerFormScreen({super.key, this.server});

  final ServerProfile? server;

  @override
  State<ServerFormScreen> createState() => _ServerFormScreenState();
}

class _ServerFormScreenState extends State<ServerFormScreen> {
  late final TextEditingController _nameController;
  late final TextEditingController _hostController;
  late final TextEditingController _portController;
  late final TextEditingController _usernameController;
  late final TextEditingController _passwordController;
  bool _obscurePassword = true;

  @override
  void initState() {
    super.initState();
    final server = widget.server;
    _nameController = TextEditingController(text: server?.name ?? '');
    _hostController = TextEditingController(text: server?.host ?? '');
    _portController = TextEditingController(
      text: server?.port.toString() ?? '22',
    );
    _usernameController = TextEditingController(text: server?.username ?? '');
    _passwordController = TextEditingController();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _hostController.dispose();
    _portController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isEditing = widget.server != null;
    return Scaffold(
      appBar: AppBar(title: Text(isEditing ? '編輯伺服器' : '新增伺服器')),
      body: SafeArea(
        child: Form(
          autovalidateMode: AutovalidateMode.onUserInteraction,
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              TextFormField(
                controller: _nameController,
                decoration: const InputDecoration(
                  labelText: '顯示名稱',
                  border: OutlineInputBorder(),
                ),
                validator: (value) =>
                    value == null || value.trim().isEmpty ? '請輸入顯示名稱' : null,
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _hostController,
                decoration: const InputDecoration(
                  labelText: '主機位址 / IP',
                  border: OutlineInputBorder(),
                ),
                validator: (value) =>
                    value == null || value.trim().isEmpty ? '請輸入主機位址' : null,
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _portController,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'SSH 連接埠',
                  border: OutlineInputBorder(),
                ),
                validator: (value) {
                  final port = int.tryParse(value ?? '');
                  if (port == null || port < 1 || port > 65535) {
                    return '連接埠需為 1-65535';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _usernameController,
                decoration: const InputDecoration(
                  labelText: 'SSH 帳號',
                  border: OutlineInputBorder(),
                ),
                validator: (value) =>
                    value == null || value.trim().isEmpty ? '請輸入 SSH 帳號' : null,
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _passwordController,
                obscureText: _obscurePassword,
                decoration: InputDecoration(
                  labelText: isEditing ? '新密碼（留白則不變更）' : 'SSH 密碼',
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    onPressed: () =>
                        setState(() => _obscurePassword = !_obscurePassword),
                    icon: Icon(
                      _obscurePassword
                          ? Icons.visibility
                          : Icons.visibility_off,
                    ),
                  ),
                ),
                validator: isEditing
                    ? null
                    : (value) =>
                          value == null || value.isEmpty ? '請輸入密碼' : null,
              ),
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: _save,
                icon: const Icon(Icons.save),
                label: Text(isEditing ? '儲存變更' : '新增伺服器'),
              ),
              const SizedBox(height: 8),
              const Text(
                '密碼會使用平台安全儲存區保存，不寫入一般設定檔。',
                style: TextStyle(fontSize: 12),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _save() async {
    final store = context.read<ServerStore>();
    final existing = widget.server;
    final password = _passwordController.text;

    if (existing == null) {
      await store.addServer(
        ServerProfile(
          id: '',
          name: _nameController.text.trim(),
          host: _hostController.text.trim(),
          port: int.parse(_portController.text),
          username: _usernameController.text.trim(),
          password: password,
          createdAt: DateTime.now(),
        ),
      );
    } else {
      await store.updateServer(
        existing.copyWith(
          name: _nameController.text.trim(),
          host: _hostController.text.trim(),
          port: int.parse(_portController.text),
          username: _usernameController.text.trim(),
        ),
        password: password,
      );
    }

    if (mounted) Navigator.of(context).pop(true);
  }
}
