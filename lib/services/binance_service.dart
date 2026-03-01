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

  final List<String> _endpoints = [
    'https://api.binance.com',
    'https://api1.binance.com',
    'https://api2.binance.com',
    'https://api3.binance.com',
  ];

  Future<List<CandleModel>> fetchHistoricalCandles(String timeframe) async {
    Object? lastError;
    
    for (final base in _endpoints) {
      final url = '$base/api/v3/klines?symbol=BTCUSDT&interval=$timeframe&limit=100';
      try {
        final response = await http.get(
          Uri.parse(url),
          headers: {
            'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36',
          },
        ).timeout(const Duration(seconds: 10));

        if (response.statusCode == 200) {
          final List<dynamic> data = jsonDecode(response.body);
          return data.map((e) => CandleModel.fromJson(e)).toList();
        } else {
          lastError = 'Binance API Error: ${response.statusCode}';
          continue; // Try next endpoint
        }
      } on TimeoutException {
        lastError = 'Connection timed out on $base.';
        continue;
      } catch (e) {
        lastError = e;
        continue;
      }
    }
    
    throw Exception(lastError ?? 'Failed to connect to any Binance endpoint. Check your internet.');
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
