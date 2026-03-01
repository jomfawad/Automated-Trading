import 'dart:async';
import '../models/candle_model.dart';
import '../models/trade_state.dart';
import '../services/storage_service.dart';

class TradingEngine {
  final String timeframe;
  late final StorageService storageService;
  TradeState state = TradeState();

  TradingEngine({required this.timeframe}) {
    storageService = StorageService(timeframe: timeframe);
  }

  // Callbacks for UI updates
  final StreamController<void> _updateController = StreamController<void>.broadcast();
  Stream<void> get onUpdate => _updateController.stream;

  bool isBotActive = false;
  CandleModel? lastClosedCandle;

  Future<void> init() async {
    state.currentCapital = await storageService.loadCapital();
    
    // Load history markers to ensure they persist across refreshes
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
    if (!active) {
      state.clearTrade();
    }
    _notify();
  }

  Future<void> resetAccount() async {
    await storageService.clearAll();
    state.reset();
    _notify();
  }

  void processNewClose(CandleModel closedCandle) {
    if (!isBotActive) return;
    
    // Only setup if we aren't currently in an active trade
    if (state.status == TradeStatus.active) return;

    lastClosedCandle = closedCandle;
    
    // Setup Phase calculations
    state.setupEntryHigh = closedCandle.high;
    state.setupEntryLow = closedCandle.low;
    state.setupSL = (closedCandle.high + closedCandle.low) / 2;
    
    // Pre-calculate 1:2 TP levels so they can be drawn during setup
    double riskLong = state.setupEntryHigh! - state.setupSL!;
    state.setupTPHigh = state.setupEntryHigh! + (riskLong * 2);
    
    double riskShort = state.setupSL! - state.setupEntryLow!;
    state.setupTPLow = state.setupEntryLow! - (riskShort * 2);
    
    state.status = TradeStatus.setup;
    
    _notify();
  }

  void processLiveTick(double currentPrice, double? currentBid, double? currentAsk, int timestamp) {
    if (!isBotActive || state.status == TradeStatus.none || lastClosedCandle == null) return;
    if (currentBid == null || currentAsk == null) return; // Need orderbook data for true execution

    // Execution Phase
    if (state.status == TradeStatus.setup) {
      // Check Long Entry (Market Buy -> executed at Ask)
      if (currentPrice >= state.setupEntryHigh!) {
        state.isLong = true;
        // True slippage: we enter at whatever the current best ask is, even if it's worse than expected
        state.activeEntry = currentAsk; 
        state.activeSL = state.setupSL;
        // 1:2 RR -> Distance exactly double Entry to SL
        double riskDist = state.activeEntry! - state.activeSL!;
        state.activeTP = state.activeEntry! + (riskDist * 2);
        
        state.status = TradeStatus.active;
        state.postTradeEntry = state.activeEntry;
        _notify();
        return;
      }
      // Check Short Entry (Market Sell -> executed at Bid)
      else if (currentPrice <= state.setupEntryLow!) {
        state.isLong = false;
        // True slippage: enter at whatever current best bid is
        state.activeEntry = currentBid;
        state.activeSL = state.setupSL;
        // 1:2 RR -> Distance exactly double Entry to SL
        double riskDist = state.activeSL! - state.activeEntry!;
        state.activeTP = state.activeEntry! - (riskDist * 2);
        
        state.status = TradeStatus.active;
        state.postTradeEntry = state.activeEntry;
        _notify();
        return;
      }
    }

    // Management Phase
    if (state.status == TradeStatus.active) {
      double riskAmount = state.currentCapital * state.riskPercentage; // $3 on $100

      if (state.isLong) {
        // Long Position Management (Market Sell to close -> executed at Bid)
        // Check Take Profit
        if (currentBid >= state.activeTP!) {
          _closeTrade(TradeResult.win, riskAmount * 2, timestamp);
        }
        // Check Stop Loss
        else if (currentBid <= state.activeSL!) {
          if (state.lastResult == TradeResult.breakEven) return; // already handled below
          _closeTrade(TradeResult.loss, -riskAmount, timestamp);
        }
        // Check Break Even (30% to TP)
        else {
          double distEntryToTP = state.activeTP! - state.activeEntry!;
          double threshold = state.activeEntry! + (distEntryToTP * 0.30);
          if (currentPrice >= threshold && state.activeSL! < state.activeEntry!) {
             // Move SL to Entry + 10% Risk
             double distEntryToOriginalSL = state.activeEntry! - state.setupSL!;
             state.activeSL = state.activeEntry! + (distEntryToOriginalSL * 0.10);
            _notify();
          }
        }
      } else {
        // Short Position Management (Market Buy to close -> executed at Ask)
        // Check Take Profit
        if (currentAsk <= state.activeTP!) {
          _closeTrade(TradeResult.win, riskAmount * 2, timestamp);
        }
        // Check Stop Loss
        else if (currentAsk >= state.activeSL!) {
           _closeTrade(TradeResult.loss, -riskAmount, timestamp);
        }
        // Check Break Even (30% to TP)
        else {
          double distEntryToTP = state.activeEntry! - state.activeTP!;
          double threshold = state.activeEntry! - (distEntryToTP * 0.30);
          if (currentPrice <= threshold && state.activeSL! > state.activeEntry!) {
             // Move SL to Entry - 10% Risk (offset downward for short)
             double distOriginalSLToEntry = state.setupSL! - state.activeEntry!;
             state.activeSL = state.activeEntry! - (distOriginalSLToEntry * 0.10);
             _notify();
          }
        }
      }
    }
  }

  void _closeTrade(TradeResult result, double pnl, int timestamp) {
    // If we hit new moved SL, mark as BreakEven (PNL will be slightly positive from the 10% offset, covering fees roughly)
    if (result == TradeResult.loss && state.isLong && state.activeSL! > state.activeEntry!) {
        result = TradeResult.breakEven;
    }
    if (result == TradeResult.loss && !state.isLong && state.activeSL! < state.activeEntry!) {
        result = TradeResult.breakEven;
    }

    state.lastResult = result;
    state.status = TradeStatus.closed;
    state.currentCapital += pnl;

    // Record marker for chart
    if (state.activeEntry != null) {
      state.historyMarkers.add(TradeResultMarker(
        timestamp: timestamp,
        entryPrice: state.activeEntry!,
        result: result,
      ));
    }

    // Save history
    storageService.saveCapital(state.currentCapital);
    storageService.saveTradeToHistory({
      'timestamp': timestamp,
      'isLong': state.isLong,
      'entry': state.activeEntry,
      'result': result.toString(),
      'pnl': pnl,
      'capitalAfter': state.currentCapital,
    });

    // Reset setup for next candle
    state.clearTrade();
    _notify();
  }

  void _notify() {
    _updateController.add(null);
  }
}
