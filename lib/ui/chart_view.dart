import 'package:flutter/material.dart';
import 'dart:math';
import '../models/candle_model.dart';
import '../models/trade_state.dart';

class ChartView extends StatefulWidget {
  final List<CandleModel> candles;
  final TradeState tradeState;
  final double? liveBid;
  final double? liveAsk;

  const ChartView({
    Key? key,
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
  
  @override
  Widget build(BuildContext context) {
    if (widget.candles.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    return GestureDetector(
      onDoubleTap: () {
        setState(() {
          _scale = 1.0;
          _dragPan = 0.0;
        });
      },
      onScaleStart: (details) {
        _baseScale = _scale;
      },
      onScaleUpdate: (details) {
        setState(() {
           // Pinch to zoom
           _scale = (_baseScale * details.scale).clamp(0.1, 20.0);
           
           // Drag to pan (dx > 0 means dragging right, which should move view to the past)
           _dragPan -= details.focalPointDelta.dx; 
        });
      },
      child: CustomPaint(
        size: Size.infinite, // Expand to take available space
        painter: _CandlePainter(
          candles: widget.candles,
          tradeState: widget.tradeState,
          liveBid: widget.liveBid,
          liveAsk: widget.liveAsk,
          scale: _scale,
          dragPan: _dragPan,
        ),
      ),
    );
  }
}

class _CandlePainter extends CustomPainter {
  final List<CandleModel> candles;
  final TradeState tradeState;
  final double? liveBid;
  final double? liveAsk;
  final double scale;
  final double dragPan;

  _CandlePainter({
    required this.candles,
    required this.tradeState,
    this.liveBid,
    this.liveAsk,
    required this.scale,
    required this.dragPan,
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
    double maxPrice = -double.infinity;
    double minPrice = double.infinity;

    for (var c in visibleCandles) {
      if (c.high > maxPrice) maxPrice = c.high;
      if (c.low < minPrice) minPrice = c.low;
    }

    // Include active strategy lines to ensure they fit dynamically as we zoom/pan
    if (tradeState.status != TradeStatus.none) {
      if (tradeState.setupEntryHigh != null) maxPrice = max(maxPrice, tradeState.setupEntryHigh!);
      if (tradeState.setupEntryLow != null) minPrice = min(minPrice, tradeState.setupEntryLow!);
      if (tradeState.setupTPHigh != null) maxPrice = max(maxPrice, tradeState.setupTPHigh!);
      if (tradeState.setupTPLow != null) minPrice = min(minPrice, tradeState.setupTPLow!);
      if (tradeState.activeTP != null) {
        maxPrice = max(maxPrice, tradeState.activeTP!);
        minPrice = min(minPrice, tradeState.activeTP!);
      }
      if (tradeState.activeSL != null) {
        maxPrice = max(maxPrice, tradeState.activeSL!);
        minPrice = min(minPrice, tradeState.activeSL!);
      }
    }

    // Safety fallback if calculation fails
    if (maxPrice == -double.infinity || minPrice == double.infinity) {
      maxPrice = candles.last.high * 1.01;
      minPrice = candles.last.low * 0.99;
    }

    // Expand view top/bottom by 5% so candles don't touch the raw edge
    final double pricePadding = (maxPrice - minPrice) * 0.05;
    maxPrice += pricePadding;
    minPrice -= pricePadding;

    final double priceRange = maxPrice - minPrice;

    // Paint Axis Background
    final axisPaint = Paint()..color = Colors.grey.withOpacity(0.1);
    canvas.drawRect(Rect.fromLTWH(width, 0, axisWidth, height), axisPaint);

    // Y coordinate helper
    double getY(double price) {
      if (priceRange == 0) return height / 2;
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
    // 3. Draw Post-Trade Markers
    // ----------------------------------------------------
    for (var marker in tradeState.historyMarkers) {
      // Find the candle index for this timestamp
      final idx = candles.indexWhere((c) => c.timestamp == marker.timestamp);
      if (idx == -1) continue;

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
           oldDelegate.tradeState.status != tradeState.status;
  }
}
