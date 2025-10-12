import 'package:flutter/material.dart';

import '../data/thermostat_client.dart';
import '../models/thermostat.dart';

class ThermostatFormDialog extends StatefulWidget {
  const ThermostatFormDialog({required this.onSubmit, this.initial, super.key});

  final Future<Thermostat> Function(ThermostatDraft draft) onSubmit;
  final Thermostat? initial;

  @override
  State<ThermostatFormDialog> createState() => _ThermostatFormDialogState();
}

class _ThermostatFormDialogState extends State<ThermostatFormDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameController;
  late final TextEditingController _urlController;
  late final TextEditingController _minController;
  late final TextEditingController _maxController;
  String? _rangeError;
  Map<ThermostatValidationField, String> _fieldErrors = {};
  String? _submitError;
  bool _isSubmitting = false;

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    _nameController = TextEditingController(text: initial?.name ?? '');
    _urlController = TextEditingController(text: initial?.rawUrl ?? '');
    _minController = TextEditingController(
      text: initial != null ? initial.minC.toStringAsFixed(1) : '',
    );
    _maxController = TextEditingController(
      text: initial != null ? initial.maxC.toStringAsFixed(1) : '',
    );
  }

  @override
  void dispose() {
    _nameController.dispose();
    _urlController.dispose();
    _minController.dispose();
    _maxController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    FocusScope.of(context).unfocus();
    setState(() {
      _fieldErrors = {};
      _rangeError = null;
      _submitError = null;
    });

    if (!_formKey.currentState!.validate()) {
      return;
    }

    final minValue = double.tryParse(_minController.text.trim());
    final maxValue = double.tryParse(_maxController.text.trim());

    if (minValue == null || maxValue == null) {
      setState(() {
        if (minValue == null) {
          _fieldErrors = {
            ..._fieldErrors,
            ThermostatValidationField.minC: 'Enter a number.',
          };
        }
        if (maxValue == null) {
          _fieldErrors = {
            ..._fieldErrors,
            ThermostatValidationField.maxC: 'Enter a number.',
          };
        }
      });
      return;
    }

    final draft = ThermostatDraft(
      name: _nameController.text.trim(),
      rawUrl: _urlController.text.trim(),
      minC: minValue,
      maxC: maxValue,
    );

    final validation = ThermostatValidator.validate(draft);
    if (!validation.isValid) {
      setState(() {
        final map = <ThermostatValidationField, String>{};
        for (final error in validation.errors) {
          map[error.field] = error.message;
          if (error.field == ThermostatValidationField.range) {
            _rangeError = error.message;
          }
        }
        _fieldErrors = map;
      });
      return;
    }

    setState(() {
      _isSubmitting = true;
    });

    try {
      final saved = await widget.onSubmit(draft);
      if (!mounted) {
        return;
      }
      Navigator.of(context).pop(saved);
    } on ThermostatValidationException catch (error) {
      final map = <ThermostatValidationField, String>{};
      String? rangeError;
      for (final item in error.result.errors) {
        map[item.field] = item.message;
        if (item.field == ThermostatValidationField.range) {
          rangeError = item.message;
        }
      }
      if (!mounted) {
        return;
      }
      setState(() {
        _fieldErrors = map;
        _rangeError = rangeError;
        _isSubmitting = false;
      });
    } on ThermostatFetchException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _submitError = error.message;
        _isSubmitting = false;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _submitError = 'Failed to save thermostat: $error';
        _isSubmitting = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final isEditing = widget.initial != null;
    return AlertDialog(
      title: Text(isEditing ? 'Edit thermostat' : 'Add thermostat'),
      content: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: _nameController,
                decoration: InputDecoration(
                  labelText: 'Name',
                  errorText: _fieldErrors[ThermostatValidationField.name],
                ),
                textCapitalization: TextCapitalization.words,
                autofocus: true,
                enabled: !_isSubmitting,
                validator: (value) {
                  if (value == null || value.trim().isEmpty) {
                    return 'Enter a name.';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _urlController,
                decoration: InputDecoration(
                  labelText: 'Raw URL',
                  helperText: 'Use the HTTPS raw link to your Gist.',
                  errorText: _fieldErrors[ThermostatValidationField.rawUrl],
                ),
                keyboardType: TextInputType.url,
                enabled: !_isSubmitting,
                validator: (value) {
                  if (value == null || value.trim().isEmpty) {
                    return 'Enter a raw URL.';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      controller: _minController,
                      decoration: InputDecoration(
                        labelText: 'Min °C',
                        errorText: _fieldErrors[ThermostatValidationField.minC],
                      ),
                      keyboardType: const TextInputType.numberWithOptions(
                        signed: true,
                        decimal: true,
                      ),
                      enabled: !_isSubmitting,
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: TextFormField(
                      controller: _maxController,
                      decoration: InputDecoration(
                        labelText: 'Max °C',
                        errorText: _fieldErrors[ThermostatValidationField.maxC],
                      ),
                      keyboardType: const TextInputType.numberWithOptions(
                        signed: true,
                        decimal: true,
                      ),
                      enabled: !_isSubmitting,
                    ),
                  ),
                ],
              ),
              if (_rangeError != null) ...[
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    _rangeError!,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              ],
              if (_submitError != null) ...[
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    _submitError!,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _isSubmitting ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _isSubmitting ? null : _submit,
          child: _isSubmitting
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Test & Save'),
        ),
      ],
    );
  }
}
