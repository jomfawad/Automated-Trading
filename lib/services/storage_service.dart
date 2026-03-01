import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/trade_state.dart';

class StorageService {
  final String timeframe;

  StorageService({required this.timeframe});

  String get _capitalKey => 'current_capital_$timeframe';
  String get _historyKey => 'trade_history_$timeframe';

  Future<double> loadCapital() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getDouble(_capitalKey) ?? 100.0;
  }

  Future<void> saveCapital(double capital) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_capitalKey, capital);
  }

  Future<List<Map<String, dynamic>>> loadTradeHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final String? historyString = prefs.getString(_historyKey);
    if (historyString != null) {
      final List<dynamic> decoded = jsonDecode(historyString);
      return decoded.map((e) => e as Map<String, dynamic>).toList();
    }
    return [];
  }

  Future<void> saveTradeToHistory(Map<String, dynamic> trade) async {
    final prefs = await SharedPreferences.getInstance();
    final List<Map<String, dynamic>> history = await loadTradeHistory();
    history.add(trade);
    await prefs.setString(_historyKey, jsonEncode(history));
  }
  
  Future<void> clearAll() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_capitalKey);
    await prefs.remove(_historyKey);
  }
}
