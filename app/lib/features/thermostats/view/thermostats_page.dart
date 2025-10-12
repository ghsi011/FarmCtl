import 'package:flutter/material.dart';

import '../widgets/thermostat_card.dart';

class ThermostatsPage extends StatelessWidget {
  const ThermostatsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Thermostats')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: const [
          ThermostatCard(
            name: 'Main Barn',
            temperature: '20°C',
            lastUpdated: 'Updated 5 minutes ago',
            status: ThermostatStatus.normal,
          ),
          SizedBox(height: 12),
          ThermostatCard(
            name: 'Propagation Greenhouse',
            temperature: '22°C',
            lastUpdated: 'Updated 10 minutes ago',
            status: ThermostatStatus.warning,
          ),
        ],
      ),
    );
  }
}
