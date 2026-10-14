import 'package:flutter/material.dart';

class DashboardScreen extends StatelessWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'PVMS Telemetry',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(
              Icons.bluetooth_connected,
              color: Colors.blueAccent,
            ),
            onPressed: () {}, // Will connect to ELM327 later
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildStatusCard(),
            const SizedBox(height: 20),
            _buildTelemetryGrid(),
            const SizedBox(height: 20),
            _buildTTFCard(),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusCard() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E1E),
        borderRadius: BorderRadius.circular(15),
        border: Border.all(color: Colors.green, width: 2),
      ),
      child: const Column(
        children: [
          Icon(Icons.check_circle_outline, color: Colors.green, size: 48),
          SizedBox(height: 10),
          Text(
            'SYSTEM NORMAL',
            style: TextStyle(
              color: Colors.green,
              fontSize: 20,
              fontWeight: FontWeight.bold,
            ),
          ),
          Text(
            'Isolation Forest Score: 0.02 (No Anomalies)',
            style: TextStyle(color: Colors.grey),
          ),
        ],
      ),
    );
  }

  Widget _buildTelemetryGrid() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        _telemetryItem('RPM', '2,450', Icons.speed),
        _telemetryItem('Engine Temp', '92°C', Icons.thermostat),
        _telemetryItem('Speed', '65 km/h', Icons.directions_car),
      ],
    );
  }

  Widget _telemetryItem(String label, String value, IconData icon) {
    return Expanded(
      child: Card(
        color: const Color(0xFF1E1E1E),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 20),
          child: Column(
            children: [
              Icon(icon, color: Colors.blueAccent, size: 32),
              const SizedBox(height: 10),
              Text(
                value,
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                ),
              ),
              Text(
                label,
                style: const TextStyle(color: Colors.grey, fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTTFCard() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E1E),
        borderRadius: BorderRadius.circular(15),
      ),
      child: const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Predictive Health Forecast',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          SizedBox(height: 10),
          Text(
            'Estimated Time-To-Failure (TTF): > 10,000 km',
            style: TextStyle(color: Colors.blueAccent, fontSize: 16),
          ),
          SizedBox(height: 5),
          Text(
            'Based on current live data stream analysis.',
            style: TextStyle(color: Colors.grey, fontSize: 12),
          ),
        ],
      ),
    );
  }
}
