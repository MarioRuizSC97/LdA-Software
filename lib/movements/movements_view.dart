import 'package:flutter/material.dart';

import '../app/panel_layout.dart';
import '../catalog/catalog_stock.dart';
import '../sales/sale_format.dart';
import 'administrator_movements.dart';
import 'inventory_movement.dart';
import 'seller_profiles.dart';

/// Rows stop growing past this width so they stay readable on wide screens.
const double _maxContentWidth = 920;

/// On wide screens the list yields width to the summary rail: 760 keeps rows
/// readable and still fits beside the rail at ~1200 px.
const double _widePrimaryWidth = 760;
const double _wideContextWidth = 320;

/// Below this row width (in unscaled text units) the name action moves
/// under the row details.
const double _inlineActionMinWidth = 480;

/// Administrator movements screen. It replaces the catalog body, like the
/// corrections view. Seller names are resolved once per uid and cached for
/// the life of this screen; only the display name is ever shown.
class MovementsView extends StatefulWidget {
  const MovementsView({
    required this.movements,
    required this.productNames,
    required this.branchChoices,
    // Retained for callers; panel navigation now belongs to the shell header.
    required VoidCallback onClose,
    super.key,
  });

  final AdministratorMovements movements;

  /// Product names from the loaded catalog snapshot, by product id.
  final Map<String, String> productNames;

  /// Branches from the administrator catalog snapshot.
  final List<CatalogBranchChoice> branchChoices;

  @override
  State<MovementsView> createState() => _MovementsViewState();
}

typedef _BranchFilterChoice = ({String? id, String label});

class _MovementsViewState extends State<MovementsView> {
  final GlobalKey _branchFilterFieldKey = GlobalKey();

  List<_BranchFilterChoice> get _branchFilterChoices => [
    (id: null, label: 'Todas'),
    for (final choice in widget.branchChoices)
      (id: choice.branchId, label: choice.branchName),
  ];

  Future<void> _openBranchMenu() async {
    final field =
        _branchFilterFieldKey.currentContext!.findRenderObject()! as RenderBox;
    final overlay =
        Navigator.of(context).overlay!.context.findRenderObject()! as RenderBox;
    final rect =
        field.localToGlobal(Offset.zero, ancestor: overlay) & field.size;
    final theme = Theme.of(context);
    final selected = await showMenu<_BranchFilterChoice>(
      context: context,
      // Do not pass initialValue: that centers the selected row over the field
      // instead of opening a predictable list below it.
      position: RelativeRect.fromRect(
        Rect.fromLTWH(rect.left, rect.bottom + 4, rect.width, 0),
        Offset.zero & overlay.size,
      ),
      constraints: BoxConstraints.tightFor(width: rect.width),
      color: theme.colorScheme.surfaceContainer,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      items: [
        for (final choice in _branchFilterChoices)
          PopupMenuItem<_BranchFilterChoice>(
            value: choice,
            height: 48,
            labelTextStyle: WidgetStatePropertyAll(
              theme.textTheme.bodyLarge!.copyWith(
                color: theme.colorScheme.onSurface,
              ),
            ),
            child: Semantics(
              selected: choice.id == _branchId,
              child: Row(
                children: [
                  SizedBox(
                    width: 24,
                    child: choice.id == _branchId
                        ? Icon(
                            Icons.check,
                            size: 20,
                            color: theme.colorScheme.onSurface,
                          )
                        : null,
                  ),
                  const SizedBox(width: 12),
                  Expanded(child: Text(choice.label)),
                ],
              ),
            ),
          ),
      ],
    );
    if (mounted && selected != null) _selectBranch(selected.id);
  }

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
      if (entry is! InventoryMovement || entry.type.isAdministratorOnly) {
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
    final ThemeData theme = Theme.of(context);
    final InputBorder themedBorder =
        theme.inputDecorationTheme.border ?? const UnderlineInputBorder();
    final InputBorder filterBorder = themedBorder.copyWith(
      borderSide: switch (theme.cardTheme.shape) {
        final OutlinedBorder shape => shape.side,
        _ => BorderSide.none,
      },
    );
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
              Text(
                'Movimientos',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              Semantics(
                label: 'Filtrar por sucursal',
                child: IntrinsicWidth(
                  child: InputDecorator(
                    key: _branchFilterFieldKey,
                    // A filter belongs to the ledger surface, not the form's
                    // accent-focused state. Keep the theme's pill geometry.
                    decoration: InputDecoration(
                      isDense: true,
                      filled: theme.cardTheme.color != null,
                      fillColor:
                          theme.cardTheme.color ??
                          theme.colorScheme.surfaceContainerLow,
                      hoverColor: Colors.transparent,
                      border: filterBorder,
                      enabledBorder: filterBorder,
                      focusedBorder: filterBorder,
                    ).applyDefaults(theme.inputDecorationTheme),
                    child: InkWell(
                      key: const ValueKey<String>('movements-branch-filter'),
                      onTap: _openBranchMenu,
                      focusColor: Colors.transparent,
                      borderRadius: switch (filterBorder) {
                        final OutlineInputBorder border => border.borderRadius,
                        _ => null,
                      },
                      child: SizedBox(
                        height: 48,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Flexible(
                              child: IndexedStack(
                                alignment: AlignmentDirectional.centerStart,
                                index: _branchFilterChoices.indexWhere(
                                  (choice) => choice.id == _branchId,
                                ),
                                children: [
                                  for (final choice in _branchFilterChoices)
                                    Text(choice.label),
                                ],
                              ),
                            ),
                            const Icon(Icons.arrow_drop_down),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              FilledButton.tonalIcon(
                onPressed: _loading ? null : _refresh,
                icon: const Icon(Icons.refresh),
                label: const Text('Actualizar'),
              ),
            ],
          ),
        ),
        Expanded(
          child: PanelLayout(
            maxPrimaryWidth: _widePrimaryWidth,
            maxContextWidth: _wideContextWidth,
            primary: Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: _maxContentWidth),
                child: _body(),
              ),
            ),
            context: _summary(context),
          ),
        ),
      ],
    );
  }

  /// Wide-only rail: the active filter and the counts of the loaded set.
  Widget _summary(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool ready = !_loading && _failure == null;
    final Map<MovementType, int> byType = <MovementType, int>{};
    int unreadable = 0;
    for (final MovementEntry entry in _entries) {
      switch (entry) {
        case InventoryMovement(:final MovementType type):
          byType[type] = (byType[type] ?? 0) + 1;
        case UnreadableMovement():
          unreadable += 1;
      }
    }
    return Card(
      key: const ValueKey<String>('movements-context'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('Resumen', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              'Filtro: ${_branchId == null ? 'Todas' : _branchLabel(_branchId!)}',
            ),
            const SizedBox(height: 8),
            if (!ready)
              const Text('Resumen no disponible')
            else ...<Widget>[
              Text(
                'Movimientos: ${_entries.length}',
                style: theme.textTheme.titleSmall,
              ),
              for (final MovementType type in MovementType.values)
                if (byType[type] case final int count)
                  Text('${type.label}: $count'),
              if (unreadable > 0) Text('Ilegibles: $unreadable'),
            ],
          ],
        ),
      ),
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
    final Widget? actionButton = action == null
        ? null
        : FilledButton.tonal(
            onPressed: () => _editName(movement.actorId),
            child: Text(action),
          );
    return Card(
      key: ValueKey<String>('movement-${movement.id}'),
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          // A narrow or large-text row has no room beside the details for the
          // name action, so it moves below them instead of squeezing them.
          final bool stacked =
              constraints.maxWidth <
              _inlineActionMinWidth * MediaQuery.textScalerOf(context).scale(1);
          return ListTile(
            title: Text(movement.type.label),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text.rich(
                  TextSpan(
                    children: <TextSpan>[
                      TextSpan(text: '$product · '),
                      TextSpan(
                        text: quantity,
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                    ],
                  ),
                ),
                Text(
                  '${_branchLabel(movement.branchId)} · '
                  '${formatSaleDateTime(movement.occurredAt)}',
                ),
                Text(
                  actor,
                  key: ValueKey<String>('movement-actor-${movement.id}'),
                ),
                if (stacked && actionButton != null) actionButton,
              ],
            ),
            trailing: stacked ? null : actionButton,
          );
        },
      ),
    );
  }

  /// The actor label and the name action, if any. Administrator-authored
  /// rows (intake and both transfer legs) have no seller profile to read.
  (String, String?) _actor(InventoryMovement movement) {
    if (movement.type.isAdministratorOnly) {
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
