import 'package:flutter/material.dart';

import 'controllers/tracker_controller.dart';
import 'screens/dashboard_screen.dart';

class SolarTrackerApp extends StatelessWidget {
  const SolarTrackerApp({super.key, required this.controller});
  final TrackerController controller;
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Solar Tracker',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xff24734d),
        brightness: Brightness.light,
      ),
      scaffoldBackgroundColor: const Color(0xfff5f7f3),
      appBarTheme: const AppBarTheme(
        backgroundColor: Color(0xfff5f7f3),
        centerTitle: false,
      ),
      cardTheme: const CardThemeData(
        elevation: 0,
        margin: EdgeInsets.zero,
        color: Colors.white,
      ),
    ),
    home: DashboardScreen(controller: controller),
  );
}
