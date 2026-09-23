import 'package:flutter/material.dart';
import 'core/maintenance_controller.dart';
import 'ui/maintenance_screen.dart';

/// 原生入口；网络由 Dart HTTP 执行，不嵌入网页代理。
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final controller = MaintenanceController();
  runApp(MaintenanceApp(controller: controller));
  controller.restore();
}

class MaintenanceApp extends StatelessWidget {
  final MaintenanceController controller;
  const MaintenanceApp({super.key, required this.controller});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: '无纸化维护中心',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xff2869e8),
        surface: Colors.white,
        secondaryContainer: const Color(0xffeaf2ff),
        onSecondaryContainer: const Color(0xff2869e8),
        primary: const Color(0xff2869e8),
      ),
      scaffoldBackgroundColor: const Color(0xfff3f6fa),
      fontFamily: '.AppleSystemUIFont',
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
          side: const BorderSide(color: Color(0xffdfe6f0)),
        ),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
        ),
      ),
      navigationBarTheme: const NavigationBarThemeData(
        backgroundColor: Colors.white,
        indicatorColor: Color(0xffebf2ff),
      ),
      dividerColor: const Color(0xffe5ebf4),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: const Color(0xfff6f8fc),
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 15,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: Color(0xffe2e9f3)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: Color(0xffe2e9f3)),
        ),
      ),
    ),
    home: MaintenanceScreen(controller: controller),
  );
}
