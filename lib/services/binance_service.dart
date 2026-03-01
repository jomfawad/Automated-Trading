import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';
import '../models/candle_model.dart';

class BinanceService {
  WebSocketChannel? _channel;
  final StreamController<Map<String, dynamic>> _ws1mController = StreamController<Map<String, dynamic>>.broadcast();
  final StreamController<Map<String, dynamic>> _ws15mController = StreamController<Map<String, dynamic>>.broadcast();
  final StreamController<Map<String, dynamic>> _bookController = StreamController<Map<String, dynamic>>.broadcast();

  Stream<Map<String, dynamic>> get ws1mStream => _ws1mController.stream;
  Stream<Map<String, dynamic>> get ws15mStream => _ws15mController.stream;
  Stream<Map<String, dynamic>> get bookStream => _bookController.stream;

  Future<List<CandleModel>> fetchHistoricalCandles(String timeframe) async {
    final url = 'https://api.binance.com/api/v3/klines?symbol=BTCUSDT&interval=$timeframe&limit=100';
    try {
      final response = await http.get(Uri.parse(url));
      if (response.statusCode == 200) {
        final List<dynamic> data = jsonDecode(response.body);
        return data.map((e) => CandleModel.fromJson(e)).toList();
      } else {
        throw Exception('Failed to load historical candles');
      }
    } catch (e) {
      print('Error fetching historical candles: $e');
      return [];
    }
  }

  void connectWebSocket() {
    disconnectWebSocket(); // Ensure no duplicates
    // use a combined stream to get both kline and bookTicker for ask/bid
    final wsUrl = Uri.parse('wss://stream.binance.com:9443/stream?streams=btcusdt@kline_1m/btcusdt@kline_15m/btcusdt@bookTicker');
    _channel = WebSocketChannel.connect(wsUrl);

    _channel!.stream.listen(
      (message) {
        final data = jsonDecode(message);
        if (data['stream'] == 'btcusdt@kline_1m') {
           _ws1mController.add(data['data']);
        } else if (data['stream'] == 'btcusdt@kline_15m') {
           _ws15mController.add(data['data']);
        } else if (data['stream'] == 'btcusdt@bookTicker') {
           _bookController.add(data['data']);
        }
      },
      onDone: () {
        print('WebSocket closed, reconnecting...');
        Future.delayed(const Duration(seconds: 2), connectWebSocket);
      },
      onError: (error) {
        print('WebSocket error: $error, reconnecting...');
        Future.delayed(const Duration(seconds: 2), connectWebSocket);
      },
    );
  }

  void disconnectWebSocket() {
    _channel?.sink.close();
    _channel = null;
  }
}
