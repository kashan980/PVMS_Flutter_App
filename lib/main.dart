import 'package:flutter/material.dart';

import 'screens/dashboard_screen.dart';

void main() {
  runApp(const PVMSApp());
}

class PVMSApp extends StatelessWidget {
  const PVMSApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'PVMS Analytics',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        primaryColor: Colors.blueAccent,
        scaffoldBackgroundColor: const Color(0xFF121212),
      ),
      home: const DashboardScreen(),
    );
  }
}
