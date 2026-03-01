void processLiveTick(Tick tick) {
  // Log bot status
  print('Bot active: $isActive');

  // Log entry condition checks
  bool entryConditionMet = checkEntryConditions(tick);
  print('Entry condition met: $entryConditionMet');

  // Log bid/ask data availability
  if (bidDataAvailable() && askDataAvailable()) {
    print('Bid/Ask data available.');
  } else {
    print('Bid/Ask data not available.');
  }

  // Attempt to execute trade
  if (entryConditionMet) {
    executeTrade(tick);
    print('Trade executed: $tick');
  } else {
    print('No trade executed.');
  }
}