import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:capy_energy/design_system/design_system.dart';

void main() {
  testWidgets('linha zero dedicada aparece em gráfico bipolar', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 600,
            height: 300,
            child: TraceChart(
              title: 'CURRENT',
              emptyMessage: 'EMPTY',
              spots: const [FlSpot(0, -10), FlSpot(1, 12)],
              color: Colors.orange,
              minY: -20,
              maxY: 20,
              leftReservedSize: 40,
              yLabelDecimals: 0,
              showZeroLine: true,
            ),
          ),
        ),
      ),
    );

    final chart = tester.widget<LineChart>(find.byType(LineChart));
    final zeroLines = chart.data.extraLinesData.horizontalLines
        .where((line) => line.y == 0)
        .toList();

    expect(zeroLines, hasLength(1));
    expect(zeroLines.single.strokeWidth, greaterThan(1));
  });

  testWidgets('supports a second series and a custom horizontal axis', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 600,
            height: 300,
            child: TraceChart(
              title: 'POWER',
              emptyMessage: 'EMPTY',
              spots: const [FlSpot(0, -10), FlSpot(2, 12)],
              secondarySpots: const [FlSpot(0, -8), FlSpot(2, 10)],
              color: Colors.orange,
              secondaryColor: Colors.blue,
              minY: -20,
              maxY: 20,
              leftReservedSize: 40,
              yLabelDecimals: 0,
              xLabelFormatter: (value) => '${value.toStringAsFixed(1)} km',
              minimumXInterval: 0.1,
              showArea: false,
            ),
          ),
        ),
      ),
    );

    final chart = tester.widget<LineChart>(find.byType(LineChart));
    expect(chart.data.lineBarsData, hasLength(2));
    expect(chart.data.lineBarsData.last.color, Colors.blue);
    expect(chart.data.lineBarsData.first.belowBarData.show, isFalse);
    expect(find.textContaining('km'), findsWidgets);
  });

  testWidgets('exposes an optional full-screen action', (tester) async {
    var expanded = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 600,
            height: 300,
            child: TraceChart(
              title: 'SPEED',
              emptyMessage: 'EMPTY',
              spots: const [FlSpot(0, 0), FlSpot(1, 10)],
              color: Colors.green,
              minY: 0,
              maxY: 20,
              leftReservedSize: 40,
              yLabelDecimals: 0,
              onExpand: () => expanded = true,
              expandTooltip: 'Expand chart',
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byTooltip('Expand chart'));
    expect(expanded, isTrue);
  });
}
