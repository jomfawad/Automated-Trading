import 'dart:async';
import 'package:flutter/material.dart';
import 'dart:math';
import '../models/candle_model.dart';
import '../models/trade_state.dart';

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
  // Simple zoom/pan state
  double _scale = 1.0;
  double _baseScale = 1.0;
  double _dragPan = 0.0;
  
  // Stabilization and Scaling
  int _lastCandleCount = 0;
  double? _minPrice;
  double? _maxPrice;
  
  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    _lastCandleCount = widget.candles.length;
    // Refresh every second for the countdown timer
    _refreshTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (mounted) setState(() {});
    });
  }

  @override
  void didUpdateWidget(ChartView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // STABILIZATION: If a new candle arrived, adjust dragPan to keep view static
    if (widget.candles.length > _lastCandleCount) {
      final double candleWidth = 8.0 * _scale;
      final double step = candleWidth * 1.25;
      final int diff = widget.candles.length - _lastCandleCount;
      _dragPan -= (diff * step);
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
            Text(
              'No candles found for ${widget.timeframe}',
              style: const TextStyle(color: Colors.grey),
            ),
          ],
        ),
      );
    }

    return LayoutBuilder(builder: (context, constraints) {
      final double axisWidth = 60.0;
      final double width = constraints.maxWidth - axisWidth;
      
      return GestureDetector(
        onDoubleTap: () {
          setState(() {
            _scale = 1.0;
            _dragPan = 0.0;
            _minPrice = null; // Reset vertical bounds for auto-fit
            _maxPrice = null;
          });
        },
        onScaleStart: (details) {
          _baseScale = _scale;
        },
        onScaleUpdate: (details) {
          setState(() {
            final double oldScale = _scale;
            // Pinch to zoom
            _scale = (_baseScale * details.scale).clamp(0.1, 20.0);

            // FOCAL POINT ZOOMING:
            // The coordinate under the focal point shouldn't move.
            if (details.scale != 1.0) {
              final double focalX = details.localFocalPoint.dx;
              if (focalX < width) {
                final double baseCandleWidth = 8.0;
                final double oldStep = baseCandleWidth * oldScale * 1.25;
                final double newStep = baseCandleWidth * _scale * 1.25;
                
                // Content Width parameters (sync with painter logic)
                final double rightMargin = width * 0.25;
                final double oldMaxScroll = (widget.candles.length * oldStep) - width + rightMargin;
                final double oldScrollX = oldMaxScroll + _dragPan;
                
                // Calculate world index under focal point before scaling
                final double worldX = (focalX + oldScrollX) / oldStep;
                
                // Calculate new max scroll with new scale
                final double newMaxScroll = (widget.candles.length * newStep) - width + rightMargin;
                
                // newScrollX = (worldX * newStep) - focalX
                // Since newScrollX = newMaxScroll + newDragPan
                // newDragPan = (worldX * newStep) - focalX - newMaxScroll
                _dragPan = (worldX * newStep) - focalX - newMaxScroll;
              }
            }
            
            // Drag to pan (dx > 0 means dragging right, which should move view to the past)
            _dragPan -= details.focalPointDelta.dx; 
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
            dragPan: _dragPan,
            // Vertical Stabilization
            onPriceBoundsCalculated: (min, max) {
              // Only update state if bounds shift significantly to avoid jitter
              if (_minPrice == null || _maxPrice == null) {
                _minPrice = min;
                _maxPrice = max;
              } else {
                final range = _maxPrice! - _minPrice!;
                final threshold = range * 0.15; // 15% threshold for recalculation
                if (min < _minPrice! || max > _maxPrice! || (min > _minPrice! + threshold && max < _maxPrice! - threshold)) {
                   // Slowly transition to new bounds (lazy movement)
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
  final double dragPan;
  
  // Vertical Stabilization
  final Function(double min, double max) onPriceBoundsCalculated;
  final double? forcedMinPrice;
  final double? forcedMaxPrice;

  _CandlePainter({
    required this.timeframe,
    required this.candles,
    required this.tradeState,
    this.liveBid,
    this.liveAsk,
    required this.scale,
    required this.dragPan,
    required this.onPriceBoundsCalculated,
    this.forcedMinPrice,
    this.forcedMaxPrice,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (candles.isEmpty) return;

    final double axisWidth = 60.0;
    final double width = size.width - axisWidth; // Leave 60px for right y-axis
    final double height = size.height;

    // Define pixel parameters for candles
    final double baseCandleWidth = 8.0;
    final double candleWidth = baseCandleWidth * scale;
    final double spacing = candleWidth * 0.25;
    final double step = candleWidth + spacing;

    // We want a clear right margin for new candles to form
    final double rightMargin = width * 0.25; 
    
    final double totalContentWidth = candles.length * step;
    
    // Default scroll position where the latest candle sits at the edge of the margin
    final double maxScrollX = totalContentWidth - width + rightMargin;
    
    // Combining default scroll with user's panning offset
    double scrollX = maxScrollX + dragPan;
    
    // Optional Bounds Clamping: prevent excessively scrolling into the white void
    if (scrollX > maxScrollX + (width * 0.5)) {
       scrollX = maxScrollX + (width * 0.5); // Can only scroll 50% screen width past current price
    }
    if (scrollX < -width) {
       scrollX = -width; // Can only scroll 1 screen width before candle 0
    }

    // Determine which candles are actually visible based on scrolled viewport
    int startIdx = (scrollX / step).floor();
    int endIdx = ((scrollX + width) / step).ceil();
    
    startIdx = startIdx.clamp(0, candles.length - 1);
    endIdx = endIdx.clamp(0, candles.length);
    if (endIdx < startIdx) endIdx = startIdx;

    final visibleCandles = candles.sublist(startIdx, endIdx);

    // ----------------------------------------------------
    // Determine Vertical Y-Axis bounds (Price Range)
    // ----------------------------------------------------
    double naturalMax = -double.infinity;
    double naturalMin = double.infinity;

    for (var c in visibleCandles) {
      if (c.high > naturalMax) naturalMax = c.high;
      if (c.low < naturalMin) naturalMin = c.low;
    }

    // Include active strategy lines to ensure they fit dynamically as we zoom/pan
    if (tradeState.status != TradeStatus.none) {
      if (tradeState.setupEntryHigh != null) naturalMax = max(naturalMax, tradeState.setupEntryHigh!);
      if (tradeState.setupEntryLow != null) naturalMin = min(naturalMin, tradeState.setupEntryLow!);
      if (tradeState.setupTPHigh != null) naturalMax = max(naturalMax, tradeState.setupTPHigh!);
      if (tradeState.setupTPLow != null) naturalMin = min(naturalMin, tradeState.setupTPLow!);
      if (tradeState.activeTP != null) {
        naturalMax = max(naturalMax, tradeState.activeTP!);
        naturalMin = min(naturalMin, tradeState.activeTP!);
      }
      if (tradeState.activeSL != null) {
        naturalMax = max(naturalMax, tradeState.activeSL!);
        naturalMin = min(naturalMin, tradeState.activeSL!);
      }
    }

    // Safety fallback if calculation fails
    if (naturalMax == -double.infinity || naturalMin == double.infinity) {
      naturalMax = candles.last.high * 1.01;
      naturalMin = candles.last.low * 0.99;
    }

    // Expand view top/bottom by 5% so candles don't touch the raw edge
    final double padding = (naturalMax - naturalMin) * 0.05;
    naturalMax += padding;
    naturalMin -= padding;
    
    // Notify the state of the calculated bounds for stabilization
    WidgetsBinding.instance.addPostFrameCallback((_) {
      onPriceBoundsCalculated(naturalMin, naturalMax);
    });

    final double maxPrice = forcedMaxPrice ?? naturalMax;
    final double minPrice = forcedMinPrice ?? naturalMin;
    final double priceRange = maxPrice - minPrice;

    // Paint Axis Background
    final axisPaint = Paint()..color = Colors.grey.withOpacity(0.1);
    canvas.drawRect(Rect.fromLTWH(width, 0, axisWidth, height), axisPaint);

    // Y coordinate helper
    double getY(double price) {
      if (priceRange <= 0) return height / 2;
      return height - ((price - minPrice) / priceRange) * height;
    }

    // ----------------------------------------------------
    // 1. Draw Candles
    // ----------------------------------------------------
    for (int i = startIdx; i < endIdx; i++) {
      final c = candles[i];
      // Screen coordinate for this specific candle index
      final double xScreen = (i * step) - scrollX;
      
      final isBull = c.close >= c.open;
      final color = isBull ? Colors.green : Colors.red;
      
      final paint = Paint()
        ..color = color
        ..strokeWidth = 1.5;

      // Draw Wick
      canvas.drawLine(
        Offset(xScreen + candleWidth / 2, getY(c.high)),
        Offset(xScreen + candleWidth / 2, getY(c.low)),
        paint,
      );

      // Draw Body
      final bodyTop = getY(max(c.open, c.close));
      final bodyBottom = getY(min(c.open, c.close));
      final actualHeight = max(1.0, bodyBottom - bodyTop);

      canvas.drawRect(
        Rect.fromLTWH(xScreen, bodyTop, candleWidth, actualHeight),
        Paint()..color = color,
      );
    }

    // ----------------------------------------------------
    // 2. Draw Strategy Target / Top-of-Book Levels
    // ----------------------------------------------------
    void drawHorizontalLine(double price, Color color, String label, {bool isDashed = false}) {
      final y = getY(price);
      if (y < 0 || y > height) return; // Hidden out of frame

      final paint = Paint()
        ..color = color
        ..strokeWidth = 1.5;

      if (isDashed) {
        const double dashWidth = 5;
        const double dashSpace = 5;
        double startX = 0;
        while (startX < width) {
          canvas.drawLine(Offset(startX, y), Offset(startX + dashWidth, y), paint);
          startX += dashWidth + dashSpace;
        }
      } else {
        canvas.drawLine(Offset(0, y), Offset(width, y), paint);
      }

      // Draw Axis Label (Price)
      final TextPainter tp = TextPainter(
        text: TextSpan(text: "\$${price.toStringAsFixed(1)}", style: const TextStyle(color: Colors.white, fontSize: 10)),
        textDirection: TextDirection.ltr,
      );
      tp.layout();
      canvas.drawRect(Rect.fromLTWH(width, y - 8, axisWidth, 16), Paint()..color = color);
      tp.paint(canvas, Offset(width + 2, y - 6));
      
      // Draw Inner Label (ENTRY/SL/TP/ASK/BID)
      final TextPainter tpLabel = TextPainter(
        text: TextSpan(text: label, style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.bold)),
        textDirection: TextDirection.ltr,
      );
      tpLabel.layout();
      tpLabel.paint(canvas, Offset(width - tpLabel.width - 4, y - 12));
    }

    // Draw active target lines
    if (tradeState.status != TradeStatus.none) {
      bool isSetup = tradeState.status == TradeStatus.setup;

      if (tradeState.activeTP != null) {
         drawHorizontalLine(tradeState.activeTP!, Colors.green, 'TP', isDashed: isSetup);
      } else {
         if (tradeState.setupTPHigh != null) drawHorizontalLine(tradeState.setupTPHigh!, Colors.green, 'TP H', isDashed: true);
         if (tradeState.setupTPLow != null) drawHorizontalLine(tradeState.setupTPLow!, Colors.green, 'TP L', isDashed: true);
      }
      
      if (tradeState.activeSL != null) {
         drawHorizontalLine(tradeState.activeSL!, Colors.red, 'SL', isDashed: isSetup);
      } else if (tradeState.setupSL != null) {
         drawHorizontalLine(tradeState.setupSL!, Colors.red, 'SL', isDashed: true);
      }

      if (tradeState.activeEntry != null) {
         drawHorizontalLine(tradeState.activeEntry!, Colors.blue, 'ENTRY', isDashed: false);
      } else {
         if (tradeState.setupEntryHigh != null) drawHorizontalLine(tradeState.setupEntryHigh!, Colors.blue, 'ENTRY H', isDashed: true);
         if (tradeState.setupEntryLow != null) drawHorizontalLine(tradeState.setupEntryLow!, Colors.blue, 'ENTRY L', isDashed: true);
      }
    }

    // Draw Top of Book (Live Ask/Bid)
    if (liveAsk != null) {
      drawHorizontalLine(liveAsk!, Colors.redAccent.withOpacity(0.5), 'ASK', isDashed: true);
    }
    if (liveBid != null) {
      drawHorizontalLine(liveBid!, Colors.greenAccent.withOpacity(0.5), 'BID', isDashed: true);
    }
    
    // Draw Current price tick line if no order book
    if (candles.isNotEmpty && liveAsk == null && liveBid == null) {
       drawHorizontalLine(candles.last.close, Colors.grey, 'PRICE', isDashed: true);
    }

    // ----------------------------------------------------
    // 3. Draw Countdown Timer
    // ----------------------------------------------------
    if (candles.isNotEmpty) {
      // Calculate remaining time
      final now = DateTime.now().millisecondsSinceEpoch;
      final int timeframeMs = (timeframe == '1m' ? 1 : 15) * 60 * 1000;
      final lastCandleStart = candles.last.timestamp;
      final nextCandleStart = lastCandleStart + timeframeMs;
      final remainingMs = nextCandleStart - now;

      if (remainingMs > 0) {
        final remainingSec = (remainingMs / 1000).ceil();
        final minutes = (remainingSec / 60).floor();
        final seconds = remainingSec % 60;
        final timerText = "${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}";

        final double currentPrice = liveAsk ?? liveBid ?? candles.last.close;
        final double timerY = getY(currentPrice);

        if (timerY >= 0 && timerY <= height) {
          final tp = TextPainter(
            text: TextSpan(
              text: timerText,
              style: const TextStyle(color: Colors.black87, fontSize: 10, fontWeight: FontWeight.bold),
            ),
            textDirection: TextDirection.ltr,
          )..layout();

          // Draw a small background box for readability
          canvas.drawRect(
            Rect.fromLTWH(width + 2, timerY + 10, axisWidth - 4, 14),
            Paint()..color = Colors.blue.withOpacity(0.1),
          );
          tp.paint(canvas, Offset(width + 5, timerY + 11));
        }
      }
    }

    // ----------------------------------------------------
    // 4. Draw Post-Trade Markers
    // ----------------------------------------------------
    for (var marker in tradeState.historyMarkers) {
      // Find the candle index for this timestamp
      final idx = candles.indexWhere((c) => c.timestamp == marker.timestamp);
      if (idx == -1) {
         // Fallback: search by tolerance if timestamps don't match perfectly
         // (though they should in our case)
         continue;
      }

      final double xScreen = (idx * step) - scrollX;
      // Only draw if within viewport
      if (xScreen < -step || xScreen > width) continue;

      final y = getY(marker.entryPrice);
      if (y < 0 || y > height) continue;

      Color markerColor = Colors.grey;
      if (marker.result == TradeResult.win) markerColor = Colors.green;
      else if (marker.result == TradeResult.loss) markerColor = Colors.red;
      else if (marker.result == TradeResult.breakEven) markerColor = Colors.purple;

      final paint = Paint()
        ..color = markerColor
        ..strokeWidth = 3.0; // Thicker for visibility

      // Double width of candle: candleWidth * 2
      final double markerWidth = candleWidth * 2.0;
      final double startX = (xScreen + candleWidth / 2) - (markerWidth / 2);

      canvas.drawLine(Offset(startX, y), Offset(startX + markerWidth, y), paint);

      // Draw Text Label above the candle
      String text = "";
      if (marker.result == TradeResult.win) text = "WIN";
      else if (marker.result == TradeResult.loss) text = "LOST";
      else if (marker.result == TradeResult.breakEven) text = "BE";

      final textPainter = TextPainter(
        text: TextSpan(
          text: text,
          style: TextStyle(
            color: markerColor,
            fontSize: 10,
            fontWeight: FontWeight.bold,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();

      // Position text above the candle's high point or the entry line
      final candleHighY = getY(candles[idx].high);
      final labelY = min(y, candleHighY) - 15; // 15px above whichever is higher

      textPainter.paint(
        canvas,
        Offset(xScreen + candleWidth / 2 - textPainter.width / 2, labelY),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _CandlePainter oldDelegate) {
    return oldDelegate.scale != scale || 
           oldDelegate.dragPan != dragPan ||
           oldDelegate.candles.length != candles.length ||
           oldDelegate.liveBid != liveBid ||
           oldDelegate.liveAsk != liveAsk ||
           oldDelegate.tradeState.status != tradeState.status ||
           oldDelegate.tradeState.historyMarkers.length != tradeState.historyMarkers.length ||
           oldDelegate.forcedMinPrice != forcedMinPrice ||
           oldDelegate.forcedMaxPrice != forcedMaxPrice;
  }
}
