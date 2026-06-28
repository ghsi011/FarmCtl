import 'package:flutter/material.dart';

import '../data/thermostat_client.dart';
import '../models/thermostat.dart';

class ThermostatFormDialog extends StatefulWidget {
  const ThermostatFormDialog({
    required this.onSubmit,
    this.onSaveWithoutTest,
    this.initial,
    super.key,
  });

  /// Tests the sensor connection and then saves.
  final Future<Thermostat> Function(ThermostatDraft draft) onSubmit;

  /// Saves the configuration without contacting the sensor. Offered as a
  /// fallback when the connection test fails (e.g. patchy signal) so setup
  /// isn't blocked by a transient network problem.
  final Future<Thermostat> Function(ThermostatDraft draft)? onSaveWithoutTest;

  final Thermostat? initial;

  @override
  State<ThermostatFormDialog> createState() => _ThermostatFormDialogState();
}

String _formatBound(double value) {
  if (value == value.roundToDouble()) {
    return value.toStringAsFixed(0);
  }
  return value.toString(); // keeps minimal decimals, e.g. 4.5 not 4.50
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
  ThermostatDraft? _pendingDraft;

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    _nameController = TextEditingController(text: initial?.name ?? '');
    _urlController = TextEditingController(text: initial?.rawUrl ?? '');
    _minController = TextEditingController(
      text: initial != null ? _formatBound(initial.minC) : '',
    );
    _maxController = TextEditingController(
      text: initial != null ? _formatBound(initial.maxC) : '',
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
      _pendingDraft = draft;
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
        _submitError = 'Could not save. Please try again.';
        _isSubmitting = false;
      });
    }
  }

  Future<void> _saveWithoutTest() async {
    final draft = _pendingDraft;
    final handler = widget.onSaveWithoutTest;
    if (draft == null || handler == null) {
      return;
    }
    setState(() {
      _isSubmitting = true;
      _submitError = null;
    });
    try {
      final saved = await handler(draft);
      if (!mounted) {
        return;
      }
      Navigator.of(context).pop(saved);
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _submitError = 'Could not save. Please try again.';
        _isSubmitting = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final isEditing = widget.initial != null;
    final canSaveWithoutTest =
        _submitError != null &&
        _pendingDraft != null &&
        widget.onSaveWithoutTest != null;
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
                maxLength: 40,
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
                  labelText: 'Gist ID',
                  helperText: 'Enter the GitHub Gist ID (hex).',
                  errorText: _fieldErrors[ThermostatValidationField.rawUrl],
                ),
                keyboardType: TextInputType.text,
                enabled: !_isSubmitting,
                validator: (value) {
                  if (value == null || value.trim().isEmpty) {
                    return 'Enter a Gist ID.';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 12),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: TextFormField(
                      controller: _minController,
                      decoration: InputDecoration(
                        labelText: 'Min °C',
                        helperText: 'e.g. 2',
                        errorText: _fieldErrors[ThermostatValidationField.minC],
                      ),
                      keyboardType: const TextInputType.numberWithOptions(
                        signed: true,
                        decimal: true,
                      ),
                      enabled: !_isSubmitting,
                      validator: _numberValidator,
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: TextFormField(
                      controller: _maxController,
                      decoration: InputDecoration(
                        labelText: 'Max °C',
                        helperText: 'e.g. 30',
                        // The cross-field "min must be < max" error is anchored
                        // to this field rather than floating below the row.
                        errorText:
                            _fieldErrors[ThermostatValidationField.maxC] ??
                            _rangeError,
                      ),
                      keyboardType: const TextInputType.numberWithOptions(
                        signed: true,
                        decimal: true,
                      ),
                      enabled: !_isSubmitting,
                      validator: _numberValidator,
                    ),
                  ),
                ],
              ),
              if (_isSubmitting) ...[
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Testing connection…',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
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
        if (canSaveWithoutTest)
          TextButton(
            onPressed: _isSubmitting ? null : _saveWithoutTest,
            child: const Text('Save without testing'),
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

  String? _numberValidator(String? value) {
    final trimmed = value?.trim() ?? '';
    if (trimmed.isEmpty) {
      return 'Enter a number.';
    }
    if (double.tryParse(trimmed) == null) {
      return 'Enter a number.';
    }
    return null;
  }
}
