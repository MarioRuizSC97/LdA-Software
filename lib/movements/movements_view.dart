import 'package:flutter/material.dart';

import '../catalog/catalog_stock.dart';
import '../sales/sale_format.dart';
import 'administrator_movements.dart';
import 'inventory_movement.dart';
import 'seller_profiles.dart';

/// Administrator movements screen. It replaces the catalog body, like the
/// corrections view. Seller names are resolved once per uid and cached for
/// the life of this screen; only the display name is ever shown.
class MovementsView extends StatefulWidget {
  const MovementsView({
    required this.movements,
    required this.productNames,
    required this.branchChoices,
    required this.onClose,
    super.key,
  });

  final AdministratorMovements movements;

  /// Product names from the loaded catalog snapshot, by product id.
  final Map<String, String> productNames;

  /// Branches from the administrator catalog snapshot.
  final List<CatalogBranchChoice> branchChoices;
  final VoidCallback onClose;

  @override
  State<MovementsView> createState() => _MovementsViewState();
}

class _MovementsViewState extends State<MovementsView> {
  final Map<String, SellerProfileLookup> _names =
      <String, SellerProfileLookup>{};
  final Set<String> _resolving = <String>{};

  /// Per-uid count of confirmed saves; a read started before a newer save
  /// never overwrites it.
  final Map<String, int> _nameWrites = <String, int>{};
  List<MovementEntry> _entries = const <MovementEntry>[];
  String? _branchId;
  bool _loading = true;
  String? _failure;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final int generation = ++_generation;
    setState(() {
      _loading = true;
      _failure = null;
    });
    try {
      final List<MovementEntry> entries = await widget.movements.load(
        _branchId,
      );
      if (!mounted || generation != _generation) return;
      setState(() {
        _entries = entries;
        _loading = false;
      });
      _resolveNames(entries);
    } catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _entries = const <MovementEntry>[];
        _loading = false;
        _failure = movementsUnavailableMessage(error);
      });
    }
  }

  void _refresh() {
    // Failed lookups are retried; resolved names stay cached.
    _names.removeWhere(
      (String _, SellerProfileLookup lookup) =>
          lookup is SellerProfileUnavailable,
    );
    _load();
  }

  void _selectBranch(String? branchId) {
    if (branchId == _branchId) return;
    _branchId = branchId;
    _load();
  }

  void _resolveNames(List<MovementEntry> entries) {
    for (final MovementEntry entry in entries) {
      if (entry is! InventoryMovement ||
          entry.type == MovementType.stockIntake) {
        continue;
      }
      final String uid = entry.actorId;
      if (_names.containsKey(uid) || !_resolving.add(uid)) continue;
      _readProfile(uid);
    }
  }

  Future<void> _readProfile(String uid) async {
    final int writes = _nameWrites[uid] ?? 0;
    SellerProfileLookup lookup;
    try {
      lookup = await widget.movements.readProfile(uid);
    } catch (_) {
      lookup = const SellerProfileUnavailable();
    }
    _resolving.remove(uid);
    if (!mounted) return;
    // A save confirmed while this read was in flight is newer than it.
    if ((_nameWrites[uid] ?? 0) != writes) return;
    // A background failure never downgrades a confirmed name.
    if (lookup is SellerProfileUnavailable && _names[uid] is SellerNamed) {
      return;
    }
    setState(() => _names[uid] = lookup);
  }

  Future<void> _editName(String uid) async {
    final SellerProfileLookup? current = _names[uid];
    final String? saved = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) => _SellerNameDialog(
        initialName: current is SellerNamed ? current.displayName : '',
        editing: current is SellerNamed,
        submit: (String name) => widget.movements.setSellerName(uid, name),
      ),
    );
    if (!mounted) return;
    if (saved == null) {
      // A cancel may follow an uncertain write that landed: read again.
      if (_resolving.add(uid)) _readProfile(uid);
      return;
    }
    _nameWrites[uid] = (_nameWrites[uid] ?? 0) + 1;
    setState(() => _names[uid] = SellerNamed(saved));
  }

  String _branchLabel(String branchId) {
    for (final CatalogBranchChoice choice in widget.branchChoices) {
      if (choice.branchId == branchId) return choice.branchName;
    }
    return branchId;
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Wrap(
            spacing: 12,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: <Widget>[
              TextButton.icon(
                onPressed: widget.onClose,
                icon: const Icon(Icons.arrow_back),
                label: const Text('Volver'),
              ),
              Text(
                'Movimientos',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              DropdownButton<String?>(
                key: const ValueKey<String>('movements-branch-filter'),
                value: _branchId,
                onChanged: _selectBranch,
                items: <DropdownMenuItem<String?>>[
                  const DropdownMenuItem<String?>(child: Text('Todas')),
                  for (final CatalogBranchChoice choice in widget.branchChoices)
                    DropdownMenuItem<String?>(
                      value: choice.branchId,
                      child: Text(choice.branchName),
                    ),
                ],
              ),
              OutlinedButton.icon(
                onPressed: _loading ? null : _refresh,
                icon: const Icon(Icons.refresh),
                label: const Text('Actualizar'),
              ),
            ],
          ),
        ),
        Expanded(child: _body()),
      ],
    );
  }

  Widget _body() {
    if (_loading) {
      return const Center(
        child: CircularProgressIndicator(
          key: ValueKey<String>('movements-loading'),
        ),
      );
    }
    if (_failure case final String failure) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(failure, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            FilledButton(onPressed: _load, child: const Text('Reintentar')),
          ],
        ),
      );
    }
    if (_entries.isEmpty) {
      return const Center(child: Text('No hay movimientos'));
    }
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: _entries.length,
      itemBuilder: (BuildContext context, int index) =>
          switch (_entries[index]) {
            final InventoryMovement movement => _movementRow(movement),
            final UnreadableMovement entry => Card(
              key: ValueKey<String>('movement-${entry.id}'),
              child: ListTile(
                leading: const Icon(Icons.error_outline),
                title: const Text('Movimiento ilegible'),
                subtitle: Text('Identificador: ${entry.id}'),
              ),
            ),
          },
    );
  }

  Widget _movementRow(InventoryMovement movement) {
    final String product =
        widget.productNames[movement.productId] ?? movement.productId;
    final String quantity = formatSignedQuantity(
      movement.quantityScaled,
      movement.precision,
      movement.unit,
    );
    final (String actor, String? action) = _actor(movement);
    return Card(
      key: ValueKey<String>('movement-${movement.id}'),
      child: ListTile(
        title: Text(movement.type.label),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('$product · $quantity'),
            Text(
              '${_branchLabel(movement.branchId)} · '
              '${formatSaleDateTime(movement.occurredAt)}',
            ),
            Text(actor, key: ValueKey<String>('movement-actor-${movement.id}')),
          ],
        ),
        trailing: action == null
            ? null
            : TextButton(
                onPressed: () => _editName(movement.actorId),
                child: Text(action),
              ),
      ),
    );
  }

  /// The actor label and the name action, if any.
  (String, String?) _actor(InventoryMovement movement) {
    if (movement.type == MovementType.stockIntake) {
      return ('Administrador', null);
    }
    final String uid = movement.actorId;
    return switch (_names[uid]) {
      SellerNamed(:final String displayName) => (displayName, 'Editar nombre'),
      SellerUnnamed() => (unnamedSellerLabel(uid), 'Asignar nombre'),
      SellerProfileUnavailable() => (unavailableSellerLabel(uid), null),
      null => ('Cargando nombre…', null),
    };
  }
}

class _SellerNameDialog extends StatefulWidget {
  const _SellerNameDialog({
    required this.initialName,
    required this.editing,
    required this.submit,
  });

  final String initialName;
  final bool editing;
  final Future<SellerProfileResult> Function(String name) submit;

  @override
  State<_SellerNameDialog> createState() => _SellerNameDialogState();
}

class _SellerNameDialogState extends State<_SellerNameDialog> {
  late final TextEditingController _name = TextEditingController(
    text: widget.initialName,
  );
  String? _error;
  String? _lockedName;
  bool _pending = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    // After an uncertain outcome only the identical name may be retried.
    final String? name = _lockedName ?? normalizeSellerDisplayName(_name.text);
    if (name == null) {
      setState(() => _error = 'Escribe un nombre de 1 a 120 caracteres.');
      return;
    }
    setState(() {
      _pending = true;
      _error = null;
    });
    try {
      await widget.submit(name);
      if (mounted) Navigator.of(context).pop(name);
      return;
    } on SellerProfileRejectedException catch (error) {
      _finish(sellerProfileRejectionMessage(error), locked: null);
    } on SellerProfileSessionException {
      _finish(
        'La sesión de administrador ya no está activa.',
        locked: _lockedName,
      );
    } catch (_) {
      _finish(
        'No se pudo confirmar el cambio. Reintenta con el mismo nombre.',
        locked: name,
      );
    }
  }

  void _finish(String message, {required String? locked}) {
    if (!mounted) return;
    setState(() {
      _pending = false;
      _error = message;
      _lockedName = locked;
      if (locked != null) _name.text = locked;
    });
  }

  @override
  Widget build(BuildContext context) {
    final bool uncertain = _lockedName != null;
    return AlertDialog(
      title: Text(widget.editing ? 'Editar nombre' : 'Asignar nombre'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          TextField(
            key: const ValueKey<String>('seller-name-field'),
            controller: _name,
            enabled: !_pending && !uncertain,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Nombre del vendedor'),
          ),
          if (_error case final String error)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                error,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
        ],
      ),
      actions: <Widget>[
        TextButton(
          onPressed: _pending ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: _pending ? null : _save,
          child: Text(uncertain ? 'Reintentar' : 'Guardar'),
        ),
      ],
    );
  }
}
