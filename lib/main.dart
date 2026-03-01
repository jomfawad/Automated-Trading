import 'package:flutter/material.dart';
import 'ui/home_screen.dart';

void main() {
  runApp(const CryptoBotApp());
}

class CryptoBotApp extends StatelessWidget {
  const CryptoBotApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Crypto Bot',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        primarySwatch: Colors.blue,
        scaffoldBackgroundColor: Colors.white,
      ),
      home: const HomeScreen(),
    );
  }
}
