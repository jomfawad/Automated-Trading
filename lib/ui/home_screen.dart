// Method to process tick data with improved 15m candle timestamp tolerance and logging
void _processTick(Tick tick) {
    DateTime tickTime = tick.timestamp;
    DateTime candleStartTime = tickTime.subtract(Duration(minutes: tickTime.minute % 15, seconds: tickTime.second));
    DateTime candleEndTime = candleStartTime.add(Duration(minutes: 15));

    // Debug logging for timestamp handling
    print('Processing tick at: \\${tickTime.toIso8601String()}');
    print('Matching with candle from: \\${candleStartTime.toIso8601String()} to: \\${candleEndTime.toIso8601String()}');

    // Find the matching candle with timestamp tolerance
    for (Candle candle in candles) {
        if (candle.timestamp.isAfter(candleStartTime) && candle.timestamp.isBefore(candleEndTime)) {
            // Update candle data based on the tick
            candle.update(tick);
            break;
        }
    }
}
