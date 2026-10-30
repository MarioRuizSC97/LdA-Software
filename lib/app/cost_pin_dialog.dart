import 'dart:ui';

import 'package:flutter/material.dart';

import 'cost_pin_store.dart';
import 'privacy_curtain.dart';

/// Each call authorizes only its caller's currently open panel/sheet. There is
/// deliberately no app-wide unlocked flag: this is a privacy curtain only.
Future<bool> showCostPinDialog(
  BuildContext context, {
  CostPinStore? store,
  PrivacyCurtain? curtain,
  bool change = false,
}) async {
  final pinStore = store ?? CostPinStore();
  final token = curtain?.token;
  return await showCurtainedDialog<bool>(
        context: context,
        curtain: curtain,
        barrierDismissible: false,
        barrierColor: Colors.transparent,
        transitionDuration: MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : const Duration(milliseconds: 150),
        pageBuilder: (context, _, _) => Stack(
          children: [
            Positioned.fill(
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 6, sigmaY: 6),
                child: ColoredBox(color: Colors.black.withValues(alpha: 0.32)),
              ),
            ),
            _CostPinDialog(
              store: pinStore,
              change: change,
              isCurrent: () => curtain == null || curtain.isCurrent(token!),
            ),
          ],
        ),
      ) ??
      false;
}

class _CostPinDialog extends StatefulWidget {
  const _CostPinDialog({
    required this.store,
    required this.change,
    required this.isCurrent,
  });
  final CostPinStore store;
  final bool change;
  final bool Function() isCurrent;
  @override
  State<_CostPinDialog> createState() => _CostPinDialogState();
}

class _CostPinDialogState extends State<_CostPinDialog> {
  final _pin = TextEditingController();
  final _current = TextEditingController();
  final _confirm = TextEditingController();
  bool? _configured;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final configured = await widget.store.isConfigured;
      if (mounted) setState(() => _configured = configured);
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'No se pudo leer el PIN. Intenta de nuevo.');
      }
    }
  }

  @override
  void dispose() {
    _pin.dispose();
    _current.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy || _configured == null || !widget.isCurrent()) return;
    final creating = !_configured! || widget.change;
    if (!CostPinStore.isValid(_pin.text)) {
      setState(() => _error = 'El PIN debe tener de 4 a 6 dígitos.');
      return;
    }
    if (creating && _pin.text != _confirm.text) {
      setState(() => _error = 'Los PIN no coinciden.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final bool accepted;
      if (widget.change) {
        accepted = await widget.store.change(_current.text, _pin.text);
      } else if (!_configured!) {
        await widget.store.create(_pin.text);
        accepted = true;
      } else {
        accepted = await widget.store.verify(_pin.text);
      }
      if (!mounted || !widget.isCurrent()) return;
      if (accepted) {
        Navigator.of(context).pop(true);
      } else {
        setState(() => _error = 'PIN incorrecto.');
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => _error =
              'No se pudo guardar o verificar el PIN. Intenta de nuevo.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _field(TextEditingController controller, String key, String label) =>
      Padding(
        padding: const EdgeInsets.only(top: 12),
        child: TextField(
          key: ValueKey(key),
          controller: controller,
          enabled: !_busy,
          obscureText: true,
          keyboardType: TextInputType.number,
          enableSuggestions: false,
          autocorrect: false,
          decoration: InputDecoration(labelText: label),
          onSubmitted: (_) => _submit(),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final creating = _configured == false || widget.change;
    return PopScope(
      canPop: !_busy,
      child: AlertDialog(
        key: const ValueKey('cost-pin-dialog'),
        title: Text(
          widget.change
              ? 'Cambiar PIN'
              : creating
              ? 'Crea un PIN'
              : 'Ingresa el PIN',
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (creating)
                const Text(
                  'Usa de 4 a 6 dígitos. Si olvidas el PIN, borra los datos de la app en este equipo.',
                ),
              if (widget.change)
                _field(_current, 'cost-pin-current', 'PIN actual'),
              _field(_pin, 'cost-pin', widget.change ? 'PIN nuevo' : 'PIN'),
              if (creating)
                _field(_confirm, 'cost-pin-confirm', 'Confirmar PIN'),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Semantics(
                    liveRegion: true,
                    child: Text(
                      _error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: _busy ? null : () => Navigator.of(context).pop(false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: _busy || _configured == null ? null : _submit,
            child: Text(widget.change ? 'Guardar PIN' : 'Continuar'),
          ),
        ],
      ),
    );
  }
}
