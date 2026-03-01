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
  
  // These will be calculated once an entry is hit
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
    // Note: historyMarkers are kept until reset
  }
}
