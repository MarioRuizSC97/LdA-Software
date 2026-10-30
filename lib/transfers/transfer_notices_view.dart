import 'package:flutter/material.dart';

import 'package:lda_inventory/app/panel_layout.dart';
import 'package:lda_inventory/movements/inventory_movement.dart';
import 'package:lda_inventory/sales/sale_format.dart';
import 'package:lda_inventory/transfers/transfer_notice.dart';
import 'package:lda_inventory/transfers/transfer_notice_controller.dart';

/// The seller's transfer-destination inbox.
///
/// Pure presentation over [TransferNoticeState]: no popups, no implicit
/// acknowledgements, and an explicit unknown state when the book cannot be
/// loaded (never a false "zero unread").
class TransferNoticesView extends StatelessWidget {
  const TransferNoticesView({
    required this.state,
    required this.productNames,
    required this.onMarkRead,
    this.onRetry,
    super.key,
  });

  final TransferNoticeState state;
  final Map<String, String> productNames;
  final ValueChanged<String> onMarkRead;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return PanelLayout(
      context: _NoticesSummary(state: state),
      primary: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 600),
          child: Column(
            children: <Widget>[
              Semantics(
                header: true,
                child: Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                    child: Row(
                      children: <Widget>[
                        Expanded(
                          child: Text(
                            'Avisos de traslados',
                            style: theme.textTheme.titleLarge,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const Divider(height: 1),
              Expanded(child: _body(context)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _body(BuildContext context) {
    return switch (state.phase) {
      TransferNoticePhase.loading => const _LoadingBody(),
      TransferNoticePhase.error => _ErrorBody(onRetry: onRetry),
      TransferNoticePhase.ready when state.notices.isEmpty =>
        const _EmptyBody(),
      TransferNoticePhase.ready => _NoticesList(
        state: state,
        productNames: productNames,
        onMarkRead: onMarkRead,
      ),
    };
  }
}

/// Wide-only rail: unread and read counts, never a guessed zero while the
/// book is loading or failed.
class _NoticesSummary extends StatelessWidget {
  const _NoticesSummary({required this.state});

  final TransferNoticeState state;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final int? unread = state.unreadCount;
    return Card(
      key: const ValueKey<String>('notices-context'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('Resumen', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            if (unread == null)
              const Text('Resumen no disponible')
            else if (state.notices.isEmpty)
              const Text('Sin avisos por revisar')
            else ...<Widget>[
              Text('Sin leer: $unread', style: theme.textTheme.titleSmall),
              Text('Leídos: ${state.notices.length - unread}'),
              Text('Total: ${state.notices.length}'),
            ],
          ],
        ),
      ),
    );
  }
}

class _LoadingBody extends StatelessWidget {
  const _LoadingBody();

  @override
  Widget build(BuildContext context) => const Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        CircularProgressIndicator(),
        SizedBox(height: 16),
        Text('Cargando avisos de traslados…'),
      ],
    ),
  );
}

class _ErrorBody extends StatelessWidget {
  const _ErrorBody({this.onRetry});

  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const Icon(Icons.cloud_off, size: 40),
          const SizedBox(height: 16),
          const Text('No se pudieron cargar los avisos de traslados.'),
          const SizedBox(height: 8),
          const Text('No es posible confirmar si hay avisos sin leer.'),
          if (onRetry != null) ...<Widget>[
            const SizedBox(height: 16),
            FilledButton.tonal(
              key: const ValueKey<String>('notices-retry'),
              onPressed: onRetry,
              child: const Text('Reintentar'),
            ),
          ],
        ],
      ),
    ),
  );
}

class _EmptyBody extends StatelessWidget {
  const _EmptyBody();

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const Icon(Icons.inbox_outlined, size: 40),
          const SizedBox(height: 16),
          Text(
            'Sin avisos de traslados',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleMedium
                ?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          Text(
            'Cuando te envíen un traslado, aparecerá aquí.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    ),
  );
}

class _NoticesList extends StatelessWidget {
  const _NoticesList({
    required this.state,
    required this.productNames,
    required this.onMarkRead,
  });

  final TransferNoticeState state;
  final Map<String, String> productNames;
  final ValueChanged<String> onMarkRead;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (BuildContext context, BoxConstraints constraints) {
      final double cardWidth = constraints.maxWidth < 520
          ? constraints.maxWidth
          : 520;
      return ListView.separated(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        itemCount: state.notices.length,
        separatorBuilder: (BuildContext context, int index) =>
            const SizedBox(height: 8),
        itemBuilder: (BuildContext context, int index) => Center(
          child: SizedBox(
            width: cardWidth,
            child: _NoticeCard(
              notice: state.notices[index],
              isRead: state.isRead(state.notices[index].transferId),
              isPending: state.isAckPending(state.notices[index].transferId),
              productNames: productNames,
              onMarkRead: onMarkRead,
            ),
          ),
        ),
      );
    },
  );
}

class _NoticeCard extends StatelessWidget {
  const _NoticeCard({
    required this.notice,
    required this.isRead,
    required this.isPending,
    required this.productNames,
    required this.onMarkRead,
  });

  final TransferNotice notice;
  final bool isRead;
  final bool isPending;
  final Map<String, String> productNames;
  final ValueChanged<String> onMarkRead;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Semantics(
      container: true,
      label:
          'Traslado del ${formatSaleDateTime(notice.occurredAt.toLocal())}, '
          '${isRead ? 'leído' : 'sin leer'}',
      child: Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      'Traslado del ${formatSaleDateTime(notice.occurredAt.toLocal())}',
                      style: theme.textTheme.titleSmall,
                      softWrap: true,
                    ),
                  ),
                  Chip(
                    label: Text(isRead ? 'Leído' : 'Sin leer'),
                    visualDensity: VisualDensity.compact,
                    backgroundColor: isRead
                        ? null
                        : theme.colorScheme.primaryContainer,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              for (final TransferNoticeLine line in notice.lines)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        '${productNames[line.productId] ?? 'Producto no disponible'}: '
                        '${formatSignedQuantity(line.quantityScaled, line.precision, line.unit)}',
                      ),
                      if (!productNames.containsKey(line.productId))
                        Text(
                          'código ${line.productId}',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                    ],
                  ),
                ),
              const SizedBox(height: 8),
              if (!isRead)
                Align(
                  alignment: AlignmentDirectional.centerEnd,
                  child: FilledButton.tonal(
                    key: ValueKey<String>('notice-read-${notice.transferId}'),
                    onPressed: isPending
                        ? null
                        : () => onMarkRead(notice.transferId),
                    child: Text(isPending ? 'Marcando…' : 'Marcar como leído'),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
