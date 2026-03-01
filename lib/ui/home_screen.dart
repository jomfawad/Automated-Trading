import 'package:flutter/material.dart';
import '../logic/trading_engine.dart';
import '../services/binance_service.dart';
import '../models/candle_model.dart';
import '../models/trade_state.dart';
import 'chart_view.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({Key? key}) : super(key: key);

  @override
  _HomeScreenState createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with SingleTickerProviderStateMixin {
  final BinanceService _apiService = BinanceService();
  
  late TabController _tabController;
  
  final TradingEngine _engine1m = TradingEngine(timeframe: '1m');
  final TradingEngine _engine15m = TradingEngine(timeframe: '15m');
  
  List<CandleModel> _candles1m = [];
  List<CandleModel> _candles15m = [];
  
  bool _isLoading1m = true;
  bool _isLoading15m = true;
  
  double? _liveAsk;
  double? _liveBid;

  String? _connectionError;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _tabController.addListener(() {
      setState(() {});
    });
    _initApp();
  }

  Future<void> _initApp() async {
    setState(() {
      _isLoading1m = true;
      _isLoading15m = true;
      _connectionError = null;
    });

    await _engine1m.init();
    await _engine15m.init();
    
    // Load historical candles concurrently
    try {
      final results = await Future.wait([
        _apiService.fetchHistoricalCandles('1m'),
        _apiService.fetchHistoricalCandles('15m')
      ]);

      if (mounted) {
        setState(() {
          _candles1m = results[0];
          _candles15m = results[1];
          _isLoading1m = false;
          _isLoading15m = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _connectionError = e.toString().replaceAll('Exception: ', '');
          _isLoading1m = false;
          _isLoading15m = false;
        });
      }
      return; // Stop initialization if history fails
    }

    // Listen for UI updates from engines
    _engine1m.onUpdate.listen((_) { if (mounted) setState(() {}); });
    _engine15m.onUpdate.listen((_) { if (mounted) setState(() {}); });

    // Start WebSocket
    _apiService.connectWebSocket();

    _apiService.bookStream.listen((data) {
      if (mounted) {
        setState(() {
          _liveBid = double.tryParse(data['b'] ?? '');
          _liveAsk = double.tryParse(data['a'] ?? '');

          // Update both charts' last candle
          if (_liveBid != null && _liveAsk != null) {
             final double midPrice = (_liveBid! + _liveAsk!) / 2;
             
             if (_candles1m.isNotEmpty) {
                 final current1m = _candles1m.last;
                 _candles1m[_candles1m.length - 1] = CandleModel(
                   timestamp: current1m.timestamp,
                   open: current1m.open,
                   high: midPrice > current1m.high ? midPrice : current1m.high,
                   low: midPrice < current1m.low ? midPrice : current1m.low,
                   close: midPrice,
                   volume: current1m.volume,
                 );
             }
             if (_candles15m.isNotEmpty) {
                 final current15m = _candles15m.last;
                 _candles15m[_candles15m.length - 1] = CandleModel(
                   timestamp: current15m.timestamp,
                   open: current15m.open,
                   high: midPrice > current15m.high ? midPrice : current15m.high,
                   low: midPrice < current15m.low ? midPrice : current15m.low,
                   close: midPrice,
                   volume: current15m.volume,
                 );
             }
          }
        });
      }
    });

    _apiService.ws1mStream.listen((data) {
      final tick = CandleModel.fromWsJson(data);
      _processTick(tick, _candles1m, _engine1m);
    });

    _apiService.ws15mStream.listen((data) {
      final tick = CandleModel.fromWsJson(data);
      _processTick(tick, _candles15m, _engine15m);
    });
  }

  void _processTick(CandleModel tick, List<CandleModel> candlesList, TradingEngine engine) {
      if (candlesList.isNotEmpty) {
        if (candlesList.last.timestamp == tick.timestamp) {
           candlesList.last = tick; // Update live candle
        } else if (tick.timestamp > candlesList.last.timestamp) {
           // A new candle just started!
           engine.processNewClose(candlesList.last);
           candlesList.add(tick); // Add new live candle
           if (candlesList.length > 200) candlesList.removeAt(0); 
        }
      }
      engine.processLiveTick(tick.close, _liveBid, _liveAsk, tick.timestamp);
      if (mounted) setState(() {});
  }

  void _toggleGlobalBot(bool val) {
    setState(() {
      _isGlobalBotActive = val;
      _engine1m.toggleBot(val);
      _engine15m.toggleBot(val);
    });
  }

  void _resetBothAccounts() {
    _engine1m.resetAccount();
    _engine15m.resetAccount();
  }

  @override
  void dispose() {
    _apiService.disconnectWebSocket();
    _tabController.dispose();
    super.dispose();
  }

  bool _isGlobalBotActive = false;

  TradingEngine get _currentEngine => _tabController.index == 0 ? _engine1m : _engine15m;

  @override
  Widget build(BuildContext context) {
    if (_connectionError != null) {
      return Scaffold(
        backgroundColor: Colors.white,
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.cloud_off, size: 64, color: Colors.redAccent),
                const SizedBox(height: 16),
                Text(
                  'Connection Error',
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                Text(
                  _connectionError!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.grey),
                ),
                const SizedBox(height: 24),
                ElevatedButton.icon(
                  onPressed: _initApp,
                  icon: const Icon(Icons.refresh),
                  label: const Text('RETRY CONNECTION'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blueAccent,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: Colors.white, // TradingView Light theme
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 1,
        title: const Text('Multi-TF Bot', style: TextStyle(color: Colors.black87)),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh, color: Colors.blueAccent),
            onPressed: _resetBothAccounts,
            tooltip: 'Reset All Accounts',
          ),
          Switch(
            value: _isGlobalBotActive,
            onChanged: _toggleGlobalBot,
            activeColor: Colors.green,
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 450),
          child: Column(
            children: [
              const SizedBox(height: 10),
              TabBar(
                controller: _tabController,
                labelColor: Colors.blueAccent,
                unselectedLabelColor: Colors.grey,
                indicatorColor: Colors.blueAccent,
                dividerColor: Colors.transparent,
                isScrollable: true,
                tabAlignment: TabAlignment.center,
                tabs: const [
                  Tab(text: "1 MINUTE"),
                  Tab(text: "15 MINUTE"),
                ],
              ),
              const SizedBox(height: 10),
              _buildStatsHeader(_currentEngine),
              _buildLevelIndicators(_currentEngine),
              Expanded(
                child: TabBarView(
                  controller: _tabController,
                  children: [
                    _isLoading1m 
                        ? const Center(child: CircularProgressIndicator())
                        : ChartView(timeframe: '1m', candles: _candles1m, tradeState: _engine1m.state, liveBid: _liveBid, liveAsk: _liveAsk),
                    _isLoading15m 
                        ? const Center(child: CircularProgressIndicator())
                        : ChartView(timeframe: '15m', candles: _candles15m, tradeState: _engine15m.state, liveBid: _liveBid, liveAsk: _liveAsk),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStatsHeader(TradingEngine engine) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.grey.shade50,
        border: Border(bottom: BorderSide(color: Colors.grey.shade300)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('CAPITAL', style: TextStyle(fontSize: 12, color: Colors.grey, fontWeight: FontWeight.bold)),
              Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text('\$${engine.state.currentCapital.toStringAsFixed(2)}  (3% RISK)', 
                    style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Colors.black87)),
                ],
              ),
            ],
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              const Text('STATUS', style: TextStyle(fontSize: 12, color: Colors.grey, fontWeight: FontWeight.bold)),
              Text(
                engine.isBotActive ? engine.state.status.name.toUpperCase() : 'STOPPED', 
                style: TextStyle(
                  fontSize: 16, 
                  fontWeight: FontWeight.bold, 
                  color: engine.isBotActive ? Colors.green : Colors.red
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildLevelIndicators(TradingEngine engine) {
    return Column(
      children: [
        if (engine.state.status != TradeStatus.none)
          Container(
            padding: const EdgeInsets.all(8),
            color: Colors.blue.shade50,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                _levelItem('SL', engine.state.activeSL ?? engine.state.setupSL, Colors.red),
                _levelItem('ENTRY', engine.state.activeEntry ?? (engine.state.setupEntryHigh != null ? 'Setup' : null), Colors.blue),
                _levelItem('TP', engine.state.activeTP ?? '1:2', Colors.green),
              ],
            ),
          ),
      ],
    );
  }

  Widget _levelItem(String label, dynamic val, Color color) {
    if (val == null) return const SizedBox.shrink();
    String text = val is double ? val.toStringAsFixed(1) : val.toString();
    return Column(
      children: [
        Text(label, style: TextStyle(fontSize: 10, color: color, fontWeight: FontWeight.bold)),
        Text(text, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
      ],
    );
  }
}
