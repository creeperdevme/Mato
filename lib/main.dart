import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'screens/home_screen.dart';
import 'services/server_store.dart';
import 'services/ssh_service.dart';

void main() {
  runApp(const MatoApp());
}

class MatoApp extends StatelessWidget {
  const MatoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        Provider<SSHService>(create: (_) => SSHService()),
        ChangeNotifierProvider<ServerStore>(
          create: (_) => ServerStore()..load(),
        ),
      ],
      child: MaterialApp(
        title: 'Mato',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          useMaterial3: true,
          colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF0B6B3A)),
          inputDecorationTheme: const InputDecorationTheme(
            border: OutlineInputBorder(),
          ),
        ),
        darkTheme: ThemeData(
          useMaterial3: true,
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF0B6B3A),
            brightness: Brightness.dark,
          ),
          inputDecorationTheme: const InputDecorationTheme(
            border: OutlineInputBorder(),
          ),
        ),
        themeMode: ThemeMode.system,
        home: const HomeScreen(),
      ),
    );
  }
}
