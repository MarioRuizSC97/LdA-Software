import 'package:flutter/material.dart';

import '../catalog/catalog_product.dart';
import '../catalog/catalog_stock.dart';
import '../firebase/emulator_transfer_gateway.dart';
import 'transfer_draft.dart';

/// Mints the stable idempotency key for a fresh transfer.
typedef TransferIdFactory = String Function();

/// Submits one frozen draft and answers the parsed server result.
///
/// The owning shell supplies its `EmulatorTransferGateway.submitTransfer`; this
/// form never touches the SDK, a session, or a store directly.
typedef TransferSubmit = Future<TransferResult> Function(TransferDraft draft);

/// Returns the draft the owning shell still holds unresolved, if any.
typedef TransferDraftLookup = TransferDraft? Function();

const String _headerText = 'Traslado entre sucursales';
const String _stockNoticeText =
    'El servidor verifica el stock al ejecutar el traslado.';
const String _uncertainText =
    'No se pudo confirmar el resultado. Reintenta el mismo envío antes de '
    'editar.';
const String _successText = 'Traslado registrado correctamente.';
const String _replayedText =
    'El traslado ya estaba registrado; el servidor devolvió el recibo '
    'original.';
const String _sessionText =
    'Tu sesión cambió. Inicia sesión de nuevo para registrar traslados.';
const String _missingBranchesText =
    'Selecciona la sucursal de origen y la de destino.';
const String _missingProductText = 'Cada línea necesita un producto.';
const String _missingQuantityText = 'Cada línea necesita una cantidad.';
const String _tooManyLinesText = 'Máximo 50 productos por traslado.';
const String _emptyBranchesText =
    'Se necesitan al menos dos sucursales para registrar un traslado.';
const String _emptyProductsText =
    'No hay productos disponibles para trasladar.';

/// Spanish wording per AF01 validation reason. Presentation owns the text; the
/// reason enum is the only classification signal.
String _reasonMessage(TransferValidationReason reason) => switch (reason) {
  TransferValidationReason.idempotencyKey =>
    'El identificador de la transferencia no es válido.',
  TransferValidationReason.branch => 'La sucursal seleccionada no es válida.',
  TransferValidationReason.branchPair =>
    'La sucursal de origen y la de destino deben ser distintas.',
  TransferValidationReason.lines =>
    'Agrega entre 1 y 50 productos al traslado.',
  TransferValidationReason.duplicateProduct =>
    'Cada producto solo puede aparecer una vez.',
  TransferValidationReason.product => 'El código del producto no es válido.',
  TransferValidationReason.specification =>
    'La unidad o la precisión del producto no es válida.',
  TransferValidationReason.quantity =>
    'La cantidad debe ser un número positivo escrito con punto decimal.',
  TransferValidationReason.quantityRange => 'La cantidad es demasiado grande.',
};

/// Spanish wording per exact callable code. The English server message is
/// never surfaced and never parsed.
const Map<String, String> _rejectionMessages = <String, String>{
  'unauthenticated': 'Tu sesión expiró. Inicia sesión para continuar.',
  'permission-denied': 'No tienes permiso para registrar traslados.',
  'invalid-argument': 'El servidor rechazó los datos del traslado.',
  'not-found': 'La sucursal o el producto ya no existen.',
  'failed-precondition':
      'La sucursal no cumple las condiciones para este traslado.',
  'out-of-range': 'Algún valor del traslado está fuera de los límites.',
  'already-exists': 'Este traslado ya existe.',
};

const String _unknownRejectionText = 'No se pudo registrar el traslado.';

/// One editable line. The identifier keeps widget and controller identity
/// stable while other rows are added or removed.
class _LineRow {
  _LineRow({required this.id, required this.quantity});

  final String id;
  final TextEditingController quantity;
  String? productId;
  QuantitySpec? spec;
}

/// Standalone administrator inventory transfer form.
///
/// Everything is injected: the exact owner uid, the administrator's global
/// branch and product snapshot, the submit callback, and the unresolved-draft
/// lookup. The form owns controllers, pending state, the frozen confirmation
/// payload, and the uncertain display only. Role gating, the draft store, and
/// navigation belong to the caller, so this widget performs no read, no session
/// check, and no auth call.
class AdministratorTransferForm extends StatefulWidget {
  const AdministratorTransferForm({
    super.key,
    required this.ownerUserId,
    required this.branches,
    required this.products,
    required this.submitTransfer,
    required this.unresolvedDraft,
    required this.onClose,
    required this.onCompleted,
    this.createTransferId = createTransferUuidV4,
    this.initialSourceBranchId,
  });

  final String ownerUserId;
  final List<CatalogBranchChoice> branches;
  final List<CatalogProduct> products;
  final TransferSubmit submitTransfer;
  final TransferDraftLookup unresolvedDraft;
  final VoidCallback onClose;
  final ValueChanged<TransferResult> onCompleted;
  final TransferIdFactory createTransferId;
  final String? initialSourceBranchId;

  @override
  State<AdministratorTransferForm> createState() =>
      _AdministratorTransferFormState();
}

class _AdministratorTransferFormState extends State<AdministratorTransferForm> {
  final List<_LineRow> _rows = <_LineRow>[];

  int _nextRowId = 0;
  int _generation = 0;
  String? _sourceBranchId;
  String? _destinationBranchId;
  String? _activeKey;
  String? _error;
  String? _banner;
  TransferDraft? _frozenDraft;
  bool _pending = false;
  bool _dialogOpen = false;
  bool _uncertain = false;
  bool _sessionLost = false;

  @override
  void initState() {
    super.initState();
    // A retained operation is resumed, never replaced: no key is minted while
    // the shell still holds an unresolved payload.
    final TransferDraft? stored = widget.unresolvedDraft();
    if (stored != null) {
      _frozenDraft = stored;
      _uncertain = true;
      _applyDraft(stored);
      return;
    }
    _resetEditing();
  }

  @override
  void didUpdateWidget(AdministratorTransferForm oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.ownerUserId != widget.ownerUserId) {
      // A different owner must never inherit or report the previous payload.
      _generation += 1;
      _resetEditing();
      _sessionLost = false;
      _uncertain = false;
      _pending = false;
      _dialogOpen = false;
      _error = null;
      _banner = null;
    }
  }

  @override
  void dispose() {
    _generation += 1;
    for (final _LineRow row in _rows) {
      row.quantity.dispose();
    }
    super.dispose();
  }

  Map<String, String> get _branchNames => <String, String>{
    for (final CatalogBranchChoice choice in widget.branches)
      choice.branchId: choice.branchName,
  };

  Map<String, CatalogProduct> get _productIndex => <String, CatalogProduct>{
    for (final CatalogProduct product in widget.products)
      product.internalCode: product,
  };

  /// True while the payload or the controls are frozen by an in-flight or
  /// retained request, or by a lost session.
  bool get _locked => _pending || _dialogOpen || _sessionLost;

  bool get _frozen => _locked || _uncertain;

  bool get _canStartNew =>
      !_frozen && widget.branches.length >= 2 && widget.products.isNotEmpty;

  /// A retained operation can only be retried with its own frozen payload.
  bool get _canSubmit =>
      _locked ? false : (_uncertain ? _frozenDraft != null : _canStartNew);

  _LineRow _newRow({String? quantity}) => _LineRow(
    id: '${_nextRowId += 1}',
    quantity: TextEditingController(text: quantity ?? ''),
  );

  void _applyDraft(TransferDraft draft) {
    for (final _LineRow row in _rows) {
      row.quantity.dispose();
    }
    _rows
      ..clear()
      ..addAll(
        draft.lines.map(
          (TransferLine line) => _newRow(quantity: line.quantity)
            ..productId = line.productId
            ..spec = line.quantitySpec,
        ),
      );
    _sourceBranchId = draft.sourceBranchId;
    _destinationBranchId = draft.destinationBranchId;
    _activeKey = draft.idempotencyKey;
  }

  void _startFresh() {
    for (final _LineRow row in _rows) {
      row.quantity.dispose();
    }
    _rows
      ..clear()
      ..add(_newRow());
    _destinationBranchId = null;
    _frozenDraft = null;
    _activeKey = null;
  }

  /// Drops every selection: used for a first run and for a different owner,
  /// which must never inherit the previous owner's draft or key.
  void _resetEditing() {
    _startFresh();
    _sourceBranchId = _branchNames.containsKey(widget.initialSourceBranchId)
        ? widget.initialSourceBranchId
        : null;
  }

  // ---------------------------------------------------------------------
  // Submission
  // ---------------------------------------------------------------------

  Future<void> _onSubmit() async {
    if (_pending || _dialogOpen || _sessionLost) return;
    if (_uncertain) {
      final TransferDraft? retained = _frozenDraft;
      if (retained != null) await _send(retained);
      return;
    }
    if (!_canStartNew) return;
    final TransferDraft? draft = _buildDraft();
    if (draft == null) return;
    await _confirm(draft);
  }

  /// Freezes the payload before anything leaves the device.
  TransferDraft? _buildDraft() {
    final String? source = _sourceBranchId;
    final String? destination = _destinationBranchId;
    if (source == null || destination == null) {
      return _failWith(_missingBranchesText);
    }
    if (source == destination) {
      return _failWith(_reasonMessage(TransferValidationReason.branchPair));
    }
    if (_rows.isEmpty || _rows.length > transferLineLimit) {
      return _failWith(_reasonMessage(TransferValidationReason.lines));
    }

    final Set<String> seen = <String>{};
    final List<TransferLine> lines = <TransferLine>[];
    for (final _LineRow row in _rows) {
      final String? productId = row.productId;
      if (productId == null) return _failWith(_missingProductText);
      if (row.quantity.text.isEmpty) return _failWith(_missingQuantityText);
      final QuantitySpec? spec = row.spec;
      if (spec == null) {
        return _failWith(
          _reasonMessage(TransferValidationReason.specification),
        );
      }
      if (!seen.add(productId)) {
        return _failWith(
          _reasonMessage(TransferValidationReason.duplicateProduct),
        );
      }
      lines.add(
        TransferLine(
          productId: productId,
          quantity: row.quantity.text,
          quantitySpec: spec,
        ),
      );
    }

    final TransferDraft draft = TransferDraft(
      idempotencyKey: _activeKey ??= widget.createTransferId(),
      sourceBranchId: source,
      destinationBranchId: destination,
      lines: lines,
    );
    try {
      draft.validate();
    } on TransferValidationException catch (error) {
      return _failWith(_reasonMessage(error.reason));
    }
    return draft;
  }

  TransferDraft? _failWith(String message) {
    setState(() => _error = message);
    return null;
  }

  Future<void> _confirm(TransferDraft draft) async {
    setState(() {
      _dialogOpen = true;
      _frozenDraft = draft;
      _error = null;
    });
    final int generation = _generation;
    bool answered = false;
    final TransferDraft? confirmed = await showDialog<TransferDraft>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext dialogContext) => _confirmationDialog(
        draft,
        dialogContext,
        () => answered,
        () => answered = true,
      ),
    );
    final bool stale = !mounted || generation != _generation;
    if (!stale) {
      setState(() {
        _dialogOpen = false;
        // Nothing left the device, so the cancelled key is simply dropped and
        // the next confirmed operation mints a new one.
        if (confirmed == null) {
          _frozenDraft = null;
          _activeKey = null;
        }
      });
    }
    if (stale || confirmed == null) return;
    await _send(confirmed);
  }

  Future<void> _send(TransferDraft draft) async {
    if (_pending || _sessionLost) return;
    setState(() {
      _pending = true;
      _error = null;
      _banner = null;
      _uncertain = false;
      _frozenDraft = draft;
    });
    final int generation = ++_generation;

    TransferResult? result;
    Object? failure;
    try {
      result = await widget.submitTransfer(draft);
    } catch (error) {
      failure = error;
    }

    // A superseded generation, an owner change, or an unmounted form must never
    // report this answer.
    if (!mounted || generation != _generation) return;
    if (failure != null) {
      _handleFailure(failure, draft);
      return;
    }

    final TransferResult settled = result!;
    setState(() {
      _pending = false;
      _uncertain = false;
      _activeKey = null;
      _banner = settled.replayed ? _replayedText : _successText;
      _startFresh();
    });
    widget.onCompleted(settled);
  }

  void _handleFailure(Object failure, TransferDraft sent) {
    if (failure is TransferRejectedException) {
      // The server settled the key: editing and a new key become allowed.
      setState(() {
        _pending = false;
        _uncertain = false;
        _frozenDraft = null;
        _activeKey = null;
        _error = _rejectionMessages[failure.code] ?? _unknownRejectionText;
      });
      return;
    }
    if (failure is TransferSessionException) {
      setState(() {
        _pending = false;
        _uncertain = false;
        _frozenDraft = null;
        _activeKey = null;
        _sessionLost = true;
        _error = _sessionText;
      });
      widget.onClose();
      return;
    }

    // Unknown, stale, or a store refusal: the key stays unresolved and the
    // exact same payload is retried. A store refusal prefers the stored draft.
    final TransferDraft retained = failure is TransferUnresolvedException
        ? (widget.unresolvedDraft() ?? sent)
        : sent;
    setState(() {
      _pending = false;
      _uncertain = true;
      _error = null;
      _frozenDraft = retained;
      _applyDraft(retained);
    });
  }

  // ---------------------------------------------------------------------
  // Editing
  // ---------------------------------------------------------------------

  void _changeSource(String? value) => setState(() {
    _sourceBranchId = value;
    _error = null;
  });

  void _changeDestination(String? value) => setState(() {
    _destinationBranchId = value;
    _error = null;
  });

  void _chooseProduct(_LineRow row, String? productId) {
    setState(() {
      row.productId = productId;
      row.spec = _productIndex[productId]?.quantitySpec;
      _error = null;
    });
  }

  void _removeRow(_LineRow row) {
    setState(() {
      _rows.remove(row);
      row.quantity.dispose();
      if (_rows.isEmpty) _rows.add(_newRow());
      _error = null;
    });
  }

  void _addRow() {
    if (!_canStartNew || _rows.length >= transferLineLimit) return;
    setState(() => _rows.add(_newRow()));
  }

  // ---------------------------------------------------------------------
  // Rendering
  // ---------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final bool tooFewBranches = widget.branches.length < 2;
    final bool noProducts = widget.products.isEmpty;
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(
        20,
        20,
        20,
        20 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: Center(
        child: ConstrainedBox(
          key: const ValueKey<String>('transfer-content'),
          constraints: const BoxConstraints(maxWidth: 560),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Semantics(
                key: const ValueKey<String>('transfer-header-semantics'),
                header: true,
                child: Text(
                  _headerText,
                  key: const ValueKey<String>('transfer-header'),
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
              ),
              if (tooFewBranches)
                _notice(_emptyBranchesText, 'transfer-empty-branches'),
              if (noProducts)
                _notice(_emptyProductsText, 'transfer-empty-products'),
              const SizedBox(height: 16),
              _branchField(
                keyName: 'transfer-source',
                label: 'Sucursal de origen',
                value: _sourceBranchId,
                onChanged: _canStartNew ? _changeSource : null,
              ),
              const SizedBox(height: 12),
              _branchField(
                keyName: 'transfer-destination',
                label: 'Sucursal de destino',
                value: _destinationBranchId,
                onChanged: _canStartNew ? _changeDestination : null,
              ),
              const SizedBox(height: 16),
              for (final _LineRow row in _rows) _lineRow(row),
              const SizedBox(height: 8),
              Text(
                'Productos: ${_rows.length} de $transferLineLimit',
                key: const ValueKey<String>('transfer-line-counter'),
              ),
              if (_rows.length >= transferLineLimit)
                _notice(_tooManyLinesText, 'transfer-max-lines'),
              const SizedBox(height: 8),
              FilledButton.tonalIcon(
                key: const ValueKey<String>('transfer-add-line'),
                onPressed:
                    _canStartNew &&
                        _rows.length < transferLineLimit &&
                        _rows.length < widget.products.length
                    ? _addRow
                    : null,
                icon: const Icon(Icons.add),
                label: const Text('Agregar producto'),
              ),
              const SizedBox(height: 16),
              Semantics(
                key: const ValueKey<String>('transfer-notice-semantics'),
                liveRegion: true,
                child: Text(
                  _stockNoticeText,
                  key: const ValueKey<String>('transfer-notice'),
                ),
              ),
              if (_banner case final String banner) ...<Widget>[
                const SizedBox(height: 12),
                Semantics(
                  key: const ValueKey<String>('transfer-banner-semantics'),
                  liveRegion: true,
                  label: 'Resultado del traslado',
                  child: ExcludeSemantics(
                    child: Text(
                      banner,
                      key: const ValueKey<String>('transfer-banner'),
                    ),
                  ),
                ),
              ],
              if (_uncertain) ...<Widget>[
                const SizedBox(height: 12),
                _region(
                  keyName: 'transfer-uncertain',
                  semanticsKey: 'transfer-uncertain-region',
                  label: 'Resultado del traslado sin confirmar',
                  message: _uncertainText,
                ),
              ],
              if (_error case final String message) ...<Widget>[
                const SizedBox(height: 12),
                _region(
                  keyName: 'transfer-error',
                  semanticsKey: 'transfer-error-region',
                  label: 'Error del traslado',
                  message: message,
                ),
              ],
              const SizedBox(height: 20),
              Wrap(
                spacing: 12,
                runSpacing: 8,
                children: <Widget>[
                  FilledButton(
                    key: const ValueKey<String>('transfer-submit'),
                    onPressed: _canSubmit ? _onSubmit : null,
                    child: _pending
                        ? Semantics(
                            key: const ValueKey<String>('transfer-spinner'),
                            liveRegion: true,
                            label: 'Procesando el envío del traslado',
                            child: const SizedBox.square(
                              dimension: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          )
                        : Text(
                            _uncertain
                                ? 'Reintentar mismo envío'
                                : 'Registrar traslado',
                          ),
                  ),
                  FilledButton.tonal(
                    key: const ValueKey<String>('transfer-close'),
                    onPressed: _pending || _dialogOpen ? null : widget.onClose,
                    child: const Text('Cerrar'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _notice(String message, String key) => Padding(
    padding: const EdgeInsets.only(top: 8),
    child: Text(message, key: ValueKey<String>(key)),
  );

  Widget _region({
    required String keyName,
    required String semanticsKey,
    required String label,
    required String message,
  }) => Semantics(
    key: ValueKey<String>(semanticsKey),
    container: true,
    liveRegion: true,
    label: label,
    child: ExcludeSemantics(
      child: Text(message, key: ValueKey<String>(keyName)),
    ),
  );

  Widget _branchField({
    required String keyName,
    required String label,
    required String? value,
    required ValueChanged<String?>? onChanged,
  }) {
    final Map<String, String> names = _branchNames;
    final List<String> ids = names.keys.toList();
    // A frozen identity that left the snapshot stays visible and is never
    // rewritten to whatever the catalog answers now.
    if (value != null && !ids.contains(value)) ids.insert(0, value);
    return DropdownButtonFormField<String>(
      key: ValueKey<String>(keyName),
      isExpanded: true,
      initialValue: value,
      hint: const Text('Selecciona una sucursal'),
      decoration: InputDecoration(labelText: label),
      items: <DropdownMenuItem<String>>[
        for (final String id in ids)
          DropdownMenuItem<String>(value: id, child: Text(names[id] ?? id)),
      ],
      onChanged: onChanged,
    );
  }

  Widget _lineRow(_LineRow row) {
    final Map<String, CatalogProduct> index = _productIndex;
    final Set<String> taken = <String>{
      for (final _LineRow other in _rows)
        if (other != row && other.productId != null) other.productId!,
    };
    final List<String> codes = index.keys
        .where((String code) => !taken.contains(code))
        .toList();
    final String? selected = row.productId;
    if (selected != null && !codes.contains(selected)) {
      codes.insert(0, selected);
    }
    final QuantitySpec? spec = row.spec;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          DropdownButtonFormField<String>(
            key: ValueKey<String>('transfer-product-${row.id}'),
            isExpanded: true,
            initialValue: selected,
            hint: const Text('Selecciona un producto'),
            decoration: const InputDecoration(labelText: 'Producto'),
            items: <DropdownMenuItem<String>>[
              for (final String code in codes)
                DropdownMenuItem<String>(
                  value: code,
                  child: Text(index[code]?.name ?? code),
                ),
            ],
            onChanged: _canStartNew
                ? (String? value) => _chooseProduct(row, value)
                : null,
          ),
          const SizedBox(height: 4),
          Text(
            spec == null
                ? 'Selecciona un producto para ver la unidad.'
                : 'Unidad: ${spec.unit} (precisión ${spec.precision})',
            key: ValueKey<String>('transfer-unit-${row.id}'),
          ),
          const SizedBox(height: 4),
          TextFormField(
            key: ValueKey<String>('transfer-quantity-${row.id}'),
            controller: row.quantity,
            enabled: !_frozen,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              labelText: 'Cantidad',
              helperText: spec == null
                  ? 'Selecciona un producto primero.'
                  : spec.precision == 0
                  ? 'Solo números enteros.'
                  : 'Hasta ${spec.precision} decimales.',
            ),
            onChanged: (_) {
              if (_error != null) setState(() => _error = null);
            },
          ),
          if (!_frozen && _rows.length > 1)
            Align(
              alignment: Alignment.centerLeft,
              child: IconButton(
                key: ValueKey<String>('transfer-remove-${row.id}'),
                tooltip: 'Quitar producto',
                icon: const Icon(Icons.remove_circle_outline),
                onPressed: () => _removeRow(row),
              ),
            ),
        ],
      ),
    );
  }

  Widget _confirmationDialog(
    TransferDraft draft,
    BuildContext dialogContext,
    bool Function() isAnswered,
    void Function() markAnswered,
  ) {
    final Map<String, String> names = _branchNames;
    return AlertDialog(
      key: const ValueKey<String>('transfer-confirm-dialog'),
      title: const Text('Confirmar traslado'),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              'De: ${names[draft.sourceBranchId] ?? draft.sourceBranchId}',
              key: const ValueKey<String>('transfer-confirm-source'),
            ),
            Text(
              'Para: ${names[draft.destinationBranchId] ?? draft.destinationBranchId}',
              key: const ValueKey<String>('transfer-confirm-destination'),
            ),
            const SizedBox(height: 12),
            for (int index = 0; index < draft.lines.length; index += 1)
              Text(
                '${draft.lines[index].productId}: ${draft.lines[index].quantity} '
                '${draft.lines[index].quantitySpec.unit}',
                key: ValueKey<String>('transfer-confirm-line-$index'),
              ),
          ],
        ),
      ),
      actions: <Widget>[
        OutlinedButton(
          key: const ValueKey<String>('transfer-confirm-cancel'),
          onPressed: () {
            if (isAnswered()) return;
            markAnswered();
            Navigator.of(dialogContext).pop();
          },
          child: const Text('Cancelar'),
        ),
        FilledButton(
          key: const ValueKey<String>('transfer-confirm-ok'),
          onPressed: () {
            if (isAnswered()) return;
            markAnswered();
            Navigator.of(dialogContext).pop(draft);
          },
          child: const Text('Confirmar y enviar'),
        ),
      ],
    );
  }
}
