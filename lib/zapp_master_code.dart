import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'dart:ui';
import 'dart:io';

// ==========================================
// MODELS
// ==========================================

class CandleModel {
  final int timestamp;
  final double open;
  final double high;
  final double low;
  final double close;
  final double volume;

  CandleModel({
    required this.timestamp,
    required this.open,
    required this.high,
    required this.low,
    required this.close,
    required this.volume,
  });

  factory CandleModel.fromJson(List<dynamic> json) {
    return CandleModel(
      timestamp: json[0] as int,
      open: double.parse(json[1].toString()),
      high: double.parse(json[2].toString()),
      low: double.parse(json[3].toString()),
      close: double.parse(json[4].toString()),
      volume: double.parse(json[5].toString()),
    );
  }

  factory CandleModel.fromWsJson(Map<String, dynamic> json) {
    final k = json['k'];
    return CandleModel(
      timestamp: k['t'] as int,
      open: double.parse(k['o'].toString()),
      high: double.parse(k['h'].toString()),
      low: double.parse(k['l'].toString()),
      close: double.parse(k['c'].toString()),
      volume: double.parse(k['v'].toString()),
    );
  }
}

enum TradeStatus { none, setup, active, closed }
enum TradeResult { none, win, loss, breakEven }

class TradeResultMarker {
  final int timestamp;
  final double entryPrice;
  final TradeResult result;

  TradeResultMarker({
    required this.timestamp,
    required this.entryPrice,
    required this.result,
  });
}

class TradeState {
  double currentCapital = 100.0;
  final double riskPercentage = 0.03; // 3% risk

  TradeStatus status = TradeStatus.none;
  TradeResult lastResult = TradeResult.none;

  double? setupEntryHigh;
  double? setupEntryLow;
  double? setupSL;
  double? setupTPHigh;
  double? setupTPLow;
  
  double? activeEntry;
  double? activeSL;
  double? activeTP;
  bool isLong = true;

  double? postTradeEntry;
  List<TradeResultMarker> historyMarkers = [];

  void reset() {
    currentCapital = 100.0;
    historyMarkers.clear();
    clearTrade();
  }

  void clearTrade() {
    status = TradeStatus.none;
    setupEntryHigh = null;
    setupEntryLow = null;
    setupSL = null;
    setupTPHigh = null;
    setupTPLow = null;
    activeEntry = null;
    activeSL = null;
    activeTP = null;
    isLong = true;
    postTradeEntry = null;
  }

  Map<String, dynamic> toJson() => {
    'status': status.index,
    'setupEntryHigh': setupEntryHigh,
    'setupEntryLow': setupEntryLow,
    'setupSL': setupSL,
    'setupTPHigh': setupTPHigh,
    'setupTPLow': setupTPLow,
    'activeEntry': activeEntry,
    'activeSL': activeSL,
    'activeTP': activeTP,
    'isLong': isLong,
  };

  void fromJson(Map<String, dynamic> json) {
    status = TradeStatus.values[json['status'] ?? 0];
    setupEntryHigh = json['setupEntryHigh'];
    setupEntryLow = json['setupEntryLow'];
    setupSL = json['setupSL'];
    setupTPHigh = json['setupTPHigh'];
    setupTPLow = json['setupTPLow'];
    activeEntry = json['activeEntry'];
    activeSL = json['activeSL'];
    activeTP = json['activeTP'];
    isLong = json['isLong'] ?? true;
  }
}

// ==========================================
// SERVICES
// ==========================================

class BinanceService {
  WebSocketChannel? _channel;
  final StreamController<Map<String, dynamic>> _ws15mController = StreamController<Map<String, dynamic>>.broadcast();
  final StreamController<Map<String, dynamic>> _bookController = StreamController<Map<String, dynamic>>.broadcast();

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
          continue;
        }
      } on TimeoutException {
        lastError = 'Connection timed out on $base.';
        continue;
      } catch (e) {
        lastError = e;
        continue;
      }
    }
    throw Exception(lastError ?? 'Failed to connect to any Binance endpoint.');
  }

  void connectWebSocket() {
    disconnectWebSocket();
    final wsUrl = Uri.parse('wss://stream.binance.com:9443/stream?streams=btcusdt@kline_15m/btcusdt@bookTicker');
    _channel = WebSocketChannel.connect(wsUrl);

    _channel!.stream.listen(
      (message) {
        final data = jsonDecode(message);
        if (data['stream'] == 'btcusdt@kline_15m') {
           _ws15mController.add(data['data']);
        } else if (data['stream'] == 'btcusdt@bookTicker') {
           _bookController.add(data['data']);
        }
      },
      onDone: () => Future.delayed(const Duration(seconds: 2), connectWebSocket),
      onError: (error) => Future.delayed(const Duration(seconds: 2), connectWebSocket),
    );
  }

  void disconnectWebSocket() {
    _channel?.sink.close();
    _channel = null;
  }
}

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

  Future<void> saveActiveState(TradeState state) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('active_state_$timeframe', jsonEncode(state.toJson()));
  }

  Future<void> loadActiveState(TradeState state) async {
    final prefs = await SharedPreferences.getInstance();
    final String? data = prefs.getString('active_state_$timeframe');
    if (data != null) {
      state.fromJson(jsonDecode(data));
    }
  }
  
  Future<void> clearAll() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_capitalKey);
    await prefs.remove(_historyKey);
    await prefs.remove('active_state_$timeframe');
  }
}

// ==========================================
// LOGIC
// ==========================================

class TradingEngine {
  final String timeframe;
  late final StorageService storageService;
  TradeState state = TradeState();

  TradingEngine({required this.timeframe}) {
    storageService = StorageService(timeframe: timeframe);
  }

  final StreamController<void> _updateController = StreamController<void>.broadcast();
  Stream<void> get onUpdate => _updateController.stream;

  bool isBotActive = false;
  CandleModel? lastClosedCandle;

  Future<void> init() async {
    state.currentCapital = await storageService.loadCapital();
    await storageService.loadActiveState(state);
    final history = await storageService.loadTradeHistory();
    state.historyMarkers = history.map((e) {
      TradeResult result = TradeResult.none;
      String resultStr = e['result'] ?? '';
      if (resultStr.contains('win')) result = TradeResult.win;
      else if (resultStr.contains('loss')) result = TradeResult.loss;
      else if (resultStr.contains('breakEven')) result = TradeResult.breakEven;

      return TradeResultMarker(
        timestamp: e['timestamp'] as int,
        entryPrice: (e['entry'] as num).toDouble(),
        result: result,
      );
    }).toList();
    _notify();
  }

  void toggleBot(bool active) {
    isBotActive = active;
    if (!active) state.clearTrade();
    _notify();
  }

  Future<void> resetAccount() async {
    await storageService.clearAll();
    state.reset();
    _notify();
  }

  void processNewClose(CandleModel closedCandle) {
    if (!isBotActive || state.status == TradeStatus.active) return;
    lastClosedCandle = closedCandle;
    state.setupEntryHigh = closedCandle.high;
    state.setupEntryLow = closedCandle.low;
    state.setupSL = (closedCandle.high + closedCandle.low) / 2;
    double riskLong = state.setupEntryHigh! - state.setupSL!;
    state.setupTPHigh = state.setupEntryHigh! + (riskLong * 2);
    double riskShort = state.setupSL! - state.setupEntryLow!;
    state.setupTPLow = state.setupEntryLow! - (riskShort * 2);
    state.status = TradeStatus.setup;
    _notify();
  }

  void processLiveTick(double currentPrice, double? currentBid, double? currentAsk, int timestamp) {
    if (!isBotActive || state.status == TradeStatus.none || lastClosedCandle == null) return;
    if (currentBid == null || currentAsk == null) return;

    if (state.status == TradeStatus.setup) {
      if (currentPrice >= state.setupEntryHigh!) {
        state.isLong = true;
        state.activeEntry = currentAsk; 
        state.activeSL = state.setupSL;
        double riskDist = state.activeEntry! - state.activeSL!;
        state.activeTP = state.activeEntry! + (riskDist * 2);
        state.status = TradeStatus.active;
        _notify();
        return;
      } else if (currentPrice <= state.setupEntryLow!) {
        state.isLong = false;
        state.activeEntry = currentBid;
        state.activeSL = state.setupSL;
        double riskDist = state.activeSL! - state.activeEntry!;
        state.activeTP = state.activeEntry! - (riskDist * 2);
        state.status = TradeStatus.active;
        _notify();
        return;
      }
    }

    if (state.status == TradeStatus.active) {
      double riskAmount = state.currentCapital * state.riskPercentage;
      if (state.isLong) {
        if (currentBid >= state.activeTP!) {
          _closeTrade(TradeResult.win, riskAmount * 2, timestamp);
        } else if (currentBid <= state.activeSL!) {
          _closeTrade(TradeResult.loss, -riskAmount, timestamp);
        } else {
          double distEntryToTP = state.activeTP! - state.activeEntry!;
          double threshold = state.activeEntry! + (distEntryToTP * 0.30);
          if (currentPrice >= threshold && state.activeSL! < state.activeEntry!) {
             double distEntryToOriginalSL = state.activeEntry! - state.setupSL!;
             state.activeSL = state.activeEntry! + (distEntryToOriginalSL * 0.10);
             storageService.saveActiveState(state); // Update SL in persistence
             _notify();
          }
        }
      } else {
        if (currentAsk <= state.activeTP!) {
          _closeTrade(TradeResult.win, riskAmount * 2, timestamp);
        } else if (currentAsk >= state.activeSL!) {
           _closeTrade(TradeResult.loss, -riskAmount, timestamp);
        } else {
          double distEntryToTP = state.activeEntry! - state.activeTP!;
          double threshold = state.activeEntry! - (distEntryToTP * 0.30);
          if (currentPrice <= threshold && state.activeSL! > state.activeEntry!) {
             double distOriginalSLToEntry = state.setupSL! - state.activeEntry!;
             state.activeSL = state.activeEntry! - (distOriginalSLToEntry * 0.10);
             storageService.saveActiveState(state); // Update SL in persistence
             _notify();
          }
        }
      }
    }
  }

  void _closeTrade(TradeResult result, double pnl, int timestamp) {
    if (result == TradeResult.loss && state.isLong && state.activeSL! > state.activeEntry!) result = TradeResult.breakEven;
    if (result == TradeResult.loss && !state.isLong && state.activeSL! < state.activeEntry!) result = TradeResult.breakEven;

    state.lastResult = result;
    state.status = TradeStatus.closed;
    state.currentCapital += pnl;
    if (state.activeEntry != null) {
      state.historyMarkers.add(TradeResultMarker(
        timestamp: timestamp,
        entryPrice: state.activeEntry!,
        result: result,
      ));
    }
    storageService.saveCapital(state.currentCapital);
    storageService.saveTradeToHistory({
      'timestamp': timestamp,
      'isLong': state.isLong,
      'entry': state.activeEntry,
      'result': result.toString(),
      'pnl': pnl,
      'capitalAfter': state.currentCapital,
    });
    state.clearTrade();
    storageService.saveActiveState(state); // Clear from persistence
    _notify();
  }

  void _notify() {
    storageService.saveActiveState(state); // Always sync on update
    _updateController.add(null);
  }
}

// ==========================================
// UI COMPONENTS
// ==========================================

class ChartView extends StatefulWidget {
  final String timeframe;
  final List<CandleModel> candles;
  final TradeState tradeState;
  final double? liveBid;
  final double? liveAsk;

  const ChartView({
    Key? key,
    required this.timeframe,
    required this.candles,
    required this.tradeState,
    this.liveBid,
    this.liveAsk,
  }) : super(key: key);

  @override
  _ChartViewState createState() => _ChartViewState();
}

class _ChartViewState extends State<ChartView> {
  double _scale = -1.0; // Negative indicates unitialized for stabilization
  double _baseScale = 1.0;
  double _dragPan = 0.0;
  double _yScale = 1.0;
  double _baseYScale = 1.0;
  int _lastCandleCount = 0;
  double? _minPrice;
  double? _maxPrice;
  Timer? _refreshTimer;
  Offset? _lastFocalPoint;

  @override
  void initState() {
    super.initState();
    _lastCandleCount = widget.candles.length;
    _refreshTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (mounted) setState(() {});
    });
  }

  @override
  void didUpdateWidget(ChartView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.candles.length > _lastCandleCount && _scale > 0) {
      final double step = (8.0 * _scale) * 1.25;
      _dragPan -= ((widget.candles.length - _lastCandleCount) * step);
      _lastCandleCount = widget.candles.length;
    }
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }
  
  @override
  Widget build(BuildContext context) {
    if (widget.candles.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.show_chart, size: 48, color: Colors.grey),
            const SizedBox(height: 8),
            Text('No candles found for ${widget.timeframe}', style: const TextStyle(color: Colors.grey)),
          ],
        ),
      );
    }

    return LayoutBuilder(builder: (context, constraints) {
      final double axisWidth = 60.0;
      final double width = constraints.maxWidth - axisWidth;

      // Handle Initial Stabilization (Target ~50 candles visible)
      if (_scale < 0 && widget.candles.isNotEmpty) {
        const double targetVisibleCandles = 50.0;
        const double baseCandleWidth = 8.0;
        const double baseStep = baseCandleWidth * 1.25;
        _scale = (width / (targetVisibleCandles * baseStep)).clamp(0.5, 5.0);
        _dragPan = 0.0; // Start at the right (most recent)
      }
      
      return GestureDetector(
        onDoubleTap: () {
          setState(() {
            _scale = -1.0; // Reset to stabilized view
            _dragPan = 0.0;
            _minPrice = null;
            _maxPrice = null;
            _yScale = 1.0;
          });
        },
        onScaleStart: (details) {
          _baseScale = _scale;
          _baseYScale = _yScale;
          _lastFocalPoint = details.localFocalPoint;
        },
        onScaleUpdate: (details) {
          setState(() {
            final double oldScale = _scale;
            final double focalX = details.localFocalPoint.dx;
            
            // X-Axis Zoom (Time)
            if (details.scale != 1.0) {
              _scale = (_baseScale * details.horizontalScale).clamp(0.1, 20.0);
              _yScale = (_baseYScale * details.verticalScale).clamp(0.1, 20.0);
              
              if (_scale != oldScale) {
                final double oldStep = (8.0 * oldScale) * 1.25;
                final double newStep = (8.0 * _scale) * 1.25;
                final double rightMargin = width * 0.25;
                final double oldMaxScroll = (widget.candles.length * oldStep) - width + rightMargin;
                
                // Calculate "world distance" of focal point from current scroll end
                final double worldX = (focalX + (oldMaxScroll + _dragPan)) / oldStep;
                final double newMaxScroll = (widget.candles.length * newStep) - width + rightMargin;
                
                // Adjust dragPan so worldX stays at focalX
                _dragPan = (worldX * newStep) - focalX - newMaxScroll;
              }
            }

            // Panning (only if not zooming heavily, to avoid glitchiness)
            if (details.scale > 0.9 && details.scale < 1.1) {
              if (_lastFocalPoint != null) {
                _dragPan -= (details.localFocalPoint.dx - _lastFocalPoint!.dx);
              }
            }
            _lastFocalPoint = details.localFocalPoint;
          });
        },
        child: CustomPaint(
          size: Size.infinite,
          painter: _CandlePainter(
            timeframe: widget.timeframe,
            candles: widget.candles,
            tradeState: widget.tradeState,
            liveBid: widget.liveBid,
            liveAsk: widget.liveAsk,
            scale: _scale,
            yScale: _yScale,
            dragPan: _dragPan,
            onPriceBoundsCalculated: (min, max) {
              if (_minPrice == null || _maxPrice == null) {
                _minPrice = min; _maxPrice = max;
              } else {
                final range = _maxPrice! - _minPrice!;
                final threshold = range * 0.15;
                if (min < _minPrice! || max > _maxPrice! || (min > _minPrice! + threshold && max < _maxPrice! - threshold)) {
                   _minPrice = _minPrice! * 0.8 + min * 0.2;
                   _maxPrice = _maxPrice! * 0.8 + max * 0.2;
                }
              }
            },
            forcedMinPrice: _minPrice,
            forcedMaxPrice: _maxPrice,
          ),
        ),
      );
    });
  }
}

class _CandlePainter extends CustomPainter {
  final String timeframe;
  final List<CandleModel> candles;
  final TradeState tradeState;
  final double? liveBid;
  final double? liveAsk;
  final double scale;
  final double yScale;
  final double dragPan;
  final Function(double min, double max) onPriceBoundsCalculated;
  final double? forcedMinPrice;
  final double? forcedMaxPrice;

  _CandlePainter({
    required this.timeframe, required this.candles, required this.tradeState,
    this.liveBid, this.liveAsk, required this.scale, required this.yScale, required this.dragPan,
    required this.onPriceBoundsCalculated, this.forcedMinPrice, this.forcedMaxPrice,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (candles.isEmpty) return;
    final double axisWidth = 60.0;
    final double width = size.width - axisWidth;
    final double height = size.height;
    final double candleWidth = 8.0 * scale;
    final double step = candleWidth * 1.25;
    final double rightMargin = width * 0.25; 
    final double maxScrollX = (candles.length * step) - width + rightMargin;
    double scrollX = maxScrollX + dragPan;
    
    if (scrollX > maxScrollX + (width * 0.5)) scrollX = maxScrollX + (width * 0.5);
    if (scrollX < -width) scrollX = -width;

    int startIdx = (scrollX / step).floor().clamp(0, candles.length - 1);
    int endIdx = ((scrollX + width) / step).ceil().clamp(0, candles.length);
    final visibleCandles = candles.sublist(startIdx, endIdx);

    double naturalMax = -double.infinity, naturalMin = double.infinity;
    for (var c in visibleCandles) {
      if (c.high > naturalMax) naturalMax = c.high;
      if (c.low < naturalMin) naturalMin = c.low;
    }
    if (tradeState.status != TradeStatus.none) {
      if (tradeState.setupEntryHigh != null) naturalMax = max(naturalMax, tradeState.setupEntryHigh!);
      if (tradeState.setupEntryLow != null) naturalMin = min(naturalMin, tradeState.setupEntryLow!);
      if (tradeState.setupTPHigh != null) naturalMax = max(naturalMax, tradeState.setupTPHigh!);
      if (tradeState.setupTPLow != null) naturalMin = min(naturalMin, tradeState.setupTPLow!);
      if (tradeState.activeTP != null) { naturalMax = max(naturalMax, tradeState.activeTP!); naturalMin = min(naturalMin, tradeState.activeTP!); }
      if (tradeState.activeSL != null) { naturalMax = max(naturalMax, tradeState.activeSL!); naturalMin = min(naturalMin, tradeState.activeSL!); }
    }
    if (naturalMax == -double.infinity) { naturalMax = candles.last.high * 1.01; naturalMin = candles.last.low * 0.99; }
    final double padding = (naturalMax - naturalMin) * 0.05;
    naturalMax += padding; naturalMin -= padding;
    WidgetsBinding.instance.addPostFrameCallback((_) => onPriceBoundsCalculated(naturalMin, naturalMax));

    final double maxPrice = forcedMaxPrice ?? naturalMax, minPrice = forcedMinPrice ?? naturalMin;
    final double centerPrice = (maxPrice + minPrice) / 2;
    final double halfRange = ((maxPrice - minPrice) / 2) / yScale;
    final double adjustedMax = centerPrice + halfRange, adjustedMin = centerPrice - halfRange;
    final double priceRange = adjustedMax - adjustedMin;

    canvas.drawRect(Rect.fromLTWH(width, 0, axisWidth, height), Paint()..color = Colors.grey.withOpacity(0.1));
    double getY(double price) => priceRange <= 0 ? height / 2 : height - ((price - adjustedMin) / priceRange) * height;

    for (int i = startIdx; i < endIdx; i++) {
      final c = candles[i];
      final double xScreen = (i * step) - scrollX;
      final color = c.close >= c.open ? Colors.green : Colors.red;
      canvas.drawLine(Offset(xScreen + candleWidth / 2, getY(c.high)), Offset(xScreen + candleWidth / 2, getY(c.low)), Paint()..color = color..strokeWidth = 1.5);
      final bTop = getY(max(c.open, c.close)), bBot = getY(min(c.open, c.close));
      canvas.drawRect(Rect.fromLTWH(xScreen, bTop, candleWidth, max(1.0, bBot - bTop)), Paint()..color = color);
    }

    void drawHLine(double price, Color color, String label, {bool isDashed = false}) {
      final y = getY(price); if (y < 0 || y > height) return;
      final p = Paint()..color = color..strokeWidth = 1.5;
      if (isDashed) { double sx = 0; while (sx < width) { canvas.drawLine(Offset(sx, y), Offset(sx + 5, y), p); sx += 10; } }
      else canvas.drawLine(Offset(0, y), Offset(width, y), p);
      final tp = TextPainter(text: TextSpan(text: "\$${price.toStringAsFixed(1)}", style: const TextStyle(color: Colors.white, fontSize: 10)), textDirection: TextDirection.ltr)..layout();
      canvas.drawRect(Rect.fromLTWH(width, y - 8, axisWidth, 16), Paint()..color = color);
      tp.paint(canvas, Offset(width + 2, y - 6));
      final tpl = TextPainter(text: TextSpan(text: label, style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.bold)), textDirection: TextDirection.ltr)..layout();
      tpl.paint(canvas, Offset(width - tpl.width - 4, y - 12));
    }

    if (tradeState.status != TradeStatus.none) {
      bool isS = tradeState.status == TradeStatus.setup;
      if (tradeState.activeTP != null) drawHLine(tradeState.activeTP!, Colors.green, 'TP', isDashed: isS);
      else { if (tradeState.setupTPHigh != null) drawHLine(tradeState.setupTPHigh!, Colors.green, 'TP H', isDashed: true); if (tradeState.setupTPLow != null) drawHLine(tradeState.setupTPLow!, Colors.green, 'TP L', isDashed: true); }
      if (tradeState.activeSL != null) drawHLine(tradeState.activeSL!, Colors.red, 'SL', isDashed: isS); else if (tradeState.setupSL != null) drawHLine(tradeState.setupSL!, Colors.red, 'SL', isDashed: true);
      if (tradeState.activeEntry != null) drawHLine(tradeState.activeEntry!, Colors.blue, 'ENTRY');
      else { if (tradeState.setupEntryHigh != null) drawHLine(tradeState.setupEntryHigh!, Colors.blue, 'ENTRY H', isDashed: true); if (tradeState.setupEntryLow != null) drawHLine(tradeState.setupEntryLow!, Colors.blue, 'ENTRY L', isDashed: true); }
    }
    if (liveAsk != null) drawHLine(liveAsk!, Colors.redAccent.withOpacity(0.5), 'ASK', isDashed: true);
    if (liveBid != null) drawHLine(liveBid!, Colors.greenAccent.withOpacity(0.5), 'BID', isDashed: true);
    if (candles.isNotEmpty && liveAsk == null) drawHLine(candles.last.close, Colors.grey, 'PRICE', isDashed: true);

    if (candles.isNotEmpty) {
      final int remMs = (candles.last.timestamp + (timeframe == '1m' ? 60000 : 900000)) - DateTime.now().millisecondsSinceEpoch;
      if (remMs > 0) {
        final sec = (remMs / 1000).ceil(), m = (sec / 60).floor(), s = sec % 60;
        final tY = getY(liveAsk ?? liveBid ?? candles.last.close);
        if (tY >= 0 && tY <= height) {
          TextPainter(text: TextSpan(text: "${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}", style: const TextStyle(color: Colors.black87, fontSize: 10, fontWeight: FontWeight.bold)), textDirection: TextDirection.ltr)..layout()..paint(canvas, Offset(width + 5, tY + 11));
        }
      }
    }

    for (var marker in tradeState.historyMarkers) {
      final idx = candles.indexWhere((c) => c.timestamp == marker.timestamp); if (idx == -1) continue;
      final double xS = (idx * step) - scrollX; if (xS < -step || xS > width) continue;
      final y = getY(marker.entryPrice); if (y < 0 || y > height) continue;
      Color mc = marker.result == TradeResult.win ? Colors.green : (marker.result == TradeResult.loss ? Colors.red : Colors.purple);
      canvas.drawLine(Offset(xS, y), Offset(xS + candleWidth * 2, y), Paint()..color = mc..strokeWidth = 3.0);
      final tp = TextPainter(text: TextSpan(text: marker.result.name.toUpperCase(), style: TextStyle(color: mc, fontSize: 10, fontWeight: FontWeight.bold)), textDirection: TextDirection.ltr)..layout();
      tp.paint(canvas, Offset(xS + candleWidth / 2 - tp.width / 2, min(y, getY(candles[idx].high)) - 15));
    }
  }

  @override bool shouldRepaint(covariant _CandlePainter old) => old.scale != scale || old.yScale != yScale || old.dragPan != dragPan || old.candles.length != candles.length || old.liveBid != liveBid || old.liveAsk != liveAsk || old.tradeState.status != tradeState.status || old.tradeState.historyMarkers.length != tradeState.historyMarkers.length || old.forcedMinPrice != forcedMinPrice || old.forcedMaxPrice != forcedMaxPrice;
}

// ==========================================
// HOME SCREEN
// ==========================================

class HomeScreen extends StatefulWidget {
  const HomeScreen({Key? key}) : super(key: key);
  @override _HomeScreenState createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final BinanceService _apiService = BinanceService();
  final TradingEngine _engine = TradingEngine(timeframe: '15m');
  List<CandleModel> _candles = [];
  bool _isLoading = true, _isBotActive = false;
  double? _liveAsk, _liveBid;
  String? _connectionError;

  @override
  void initState() {
    super.initState();
    _initApp();
  }

  Future<void> _initApp() async {
    setState(() { _isLoading = true; _connectionError = null; });
    await _engine.init();
    try {
      final results = await _apiService.fetchHistoricalCandles('15m');
      setState(() { _candles = results; _isLoading = false; });
    } catch (e) {
      setState(() { _connectionError = e.toString().replaceAll('Exception: ', ''); _isLoading = false; });
      return;
    }
    _engine.onUpdate.listen((_) => setState(() {}));
    _apiService.connectWebSocket();
    _apiService.bookStream.listen((data) {
      setState(() {
        _liveBid = double.tryParse(data['b'] ?? ''); _liveAsk = double.tryParse(data['a'] ?? '');
        if (_liveBid != null && _liveAsk != null) {
           final mid = (_liveBid! + _liveAsk!) / 2;
           if (_candles.isNotEmpty) { final l = _candles.last; _candles[_candles.length-1] = CandleModel(timestamp: l.timestamp, open: l.open, high: max(l.high, mid), low: min(l.low, mid), close: mid, volume: l.volume); }
        }
      });
    });
    _apiService.ws15mStream.listen((data) => _proc(CandleModel.fromWsJson(data), _candles, _engine));
  }

  void _proc(CandleModel tick, List<CandleModel> list, TradingEngine engine) {
      if (list.isNotEmpty) {
        if (list.last.timestamp == tick.timestamp) list.last = tick;
        else if (tick.timestamp > list.last.timestamp) { engine.processNewClose(list.last); list.add(tick); if (list.length > 200) list.removeAt(0); }
      }
      engine.processLiveTick(tick.close, _liveBid, _liveAsk, tick.timestamp);
      setState(() {});
  }

  void _toggle(bool val) { setState(() { _isBotActive = val; _engine.toggleBot(val); }); }

  @override
  void dispose() { _apiService.disconnectWebSocket(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    if (_connectionError != null) {
      return Scaffold(body: Center(child: Padding(padding: const EdgeInsets.all(32), child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        const Icon(Icons.cloud_off, size: 64, color: Colors.redAccent), const SizedBox(height: 16),
        Text('Connection Error', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)), const SizedBox(height: 8),
        Text(_connectionError!, textAlign: TextAlign.center, style: const TextStyle(color: Colors.grey)), const SizedBox(height: 24),
        ElevatedButton.icon(onPressed: _initApp, icon: const Icon(Icons.refresh), label: const Text('RETRY CONNECTION')),
      ]))));
    }
    return Scaffold(
      appBar: AppBar(title: const Text('15m Crypto Bot'), actions: [
        IconButton(icon: const Icon(Icons.refresh), onPressed: () { _engine.resetAccount(); }),
        Switch(value: _isBotActive, onChanged: _toggle, activeColor: Colors.green),
      ]),
      body: Column(children: [
        Container(padding: const EdgeInsets.all(16), child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('CAPITAL', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
            Text('\$${_engine.state.currentCapital.toStringAsFixed(2)}', style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
          ]),
          Text(_engine.isBotActive ? _engine.state.status.name.toUpperCase() : 'STOPPED', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: _engine.isBotActive ? Colors.green : Colors.red)),
        ])),
        if (_engine.state.status != TradeStatus.none) Container(padding: const EdgeInsets.all(8), color: Colors.blue.shade50, child: Row(mainAxisAlignment: MainAxisAlignment.spaceAround, children: [
          _level('SL', _engine.state.activeSL ?? _engine.state.setupSL, Colors.red),
          _level('ENTRY', _engine.state.activeEntry ?? (_engine.state.setupEntryHigh != null ? 'Setup' : null), Colors.blue),
          _level('TP', _engine.state.activeTP ?? '1:2', Colors.green),
        ])),
        Expanded(
          child: _isLoading 
            ? const Center(child: CircularProgressIndicator()) 
            : ChartView(timeframe: '15m', candles: _candles, tradeState: _engine.state, liveBid: _liveBid, liveAsk: _liveAsk),
        ),
      ]),
    );
  }
  Widget _level(String l, dynamic v, Color c) => Column(children: [Text(l, style: TextStyle(fontSize: 10, color: c, fontWeight: FontWeight.bold)), Text(v is double ? v.toStringAsFixed(1) : v.toString(), style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold))]);
}

// ==========================================
// BACKGROUND SERVICE
// ==========================================

Future<void> initializeService() async {
  final service = FlutterBackgroundService();

  const AndroidNotificationChannel channel = AndroidNotificationChannel(
    'crypto_bot_foreground',
    'Crypto Bot Service',
    description: 'This channel is used for the bot execution.',
    importance: Importance.low,
  );

  final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin = FlutterLocalNotificationsPlugin();

  if (Platform.isAndroid) {
    await flutterLocalNotificationsPlugin
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(channel);
  }

  await service.configure(
    androidConfiguration: AndroidConfiguration(
      onStart: onStart,
      autoStart: true,
      isForegroundMode: true,
      notificationChannelId: 'crypto_bot_foreground',
      initialNotificationTitle: 'Crypto Bot Active',
      initialNotificationContent: 'Monitoring 15m Timeframe...',
      foregroundServiceNotificationId: 888,
    ),
    iosConfiguration: IosConfiguration(
       autoStart: true,
       onForeground: onStart,
       onBackground: onIosBackground,
    ),
  );

  service.startService();
}

@pragma('vm:entry-point')
Future<bool> onIosBackground(ServiceInstance service) async => true;

@pragma('vm:entry-point')
void onStart(ServiceInstance service) async {
  DartPluginRegistrant.ensureInitialized();

  final BinanceService api = BinanceService();
  final TradingEngine engine = TradingEngine(timeframe: '15m');
  List<CandleModel> candles = [];
  double? liveBid, liveAsk;

  await engine.init();
  api.connectWebSocket();

  api.bookStream.listen((data) {
    liveBid = double.tryParse(data['b'] ?? '');
    liveAsk = double.tryParse(data['a'] ?? '');
    if (liveBid != null && liveAsk != null && candles.isNotEmpty) {
      final mid = (liveBid! + liveAsk!) / 2;
      final last = candles.last;
      candles[candles.length - 1] = CandleModel(
        timestamp: last.timestamp,
        open: last.open,
        high: max(last.high, mid),
        low: min(last.low, mid),
        close: mid,
        volume: last.volume,
      );
    }
  });

  api.ws15mStream.listen((data) {
    final tick = CandleModel.fromWsJson(data);
    if (candles.isNotEmpty) {
      if (candles.last.timestamp == tick.timestamp) {
        candles[candles.length - 1] = tick;
      } else if (tick.timestamp > candles.last.timestamp) {
        engine.processNewClose(candles.last);
        candles.add(tick);
        if (candles.length > 200) candles.removeAt(0);
      }
    } else {
      candles.add(tick);
    }
    engine.processLiveTick(tick.close, liveBid, liveAsk, tick.timestamp);
  });

  service.on('stopService').listen((event) {
    service.stopSelf();
  });

  Timer.periodic(const Duration(seconds: 10), (timer) async {
    if (service is AndroidServiceInstance) {
      if (await service.isForegroundService()) {
        service.setForegroundNotificationInfo(
          title: "Crypto Bot Active",
          content: "Capital: \$${engine.state.currentCapital.toStringAsFixed(2)} | Status: ${engine.state.status.name.toUpperCase()}",
        );
      }
    }
  });
}

// ==========================================
// MAIN ENTRY
// ==========================================

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeService();
  runApp(const MaterialApp(home: HomeScreen(), debugShowCheckedModeBanner: false));
}
