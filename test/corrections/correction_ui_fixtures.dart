import 'dart:async';

import 'package:lda_inventory/corrections/correction_draft.dart';
import 'package:lda_inventory/corrections/correction_receipt.dart';
import 'package:lda_inventory/corrections/correction_sale.dart';
import 'package:lda_inventory/corrections/sale_corrections.dart';
import 'package:lda_inventory/firebase/emulator_sale_gateway.dart';
import 'package:lda_inventory/sales/sale_cart.dart';

import '../sales/sale_fixtures.dart';
import 'correction_fixtures.dart';

/// Answers a preview or submit with the generic server-shaped amounts.
const Object answerNormally = Object();

/// Answers a submit as a replay of an already registered return.
const Object answerReplayed = #replayed;

/// Fake seller correction operations that behave like the shell: one
/// unresolved draft per seller, kept on anything but a success or a
/// deterministic rejection. Queued results are [answerNormally],
/// [answerReplayed], a [Completer], or an error to throw.
class FakeCorrections {
  FakeCorrections({this.unresolved});

  SaleCorrectionDraft? unresolved;
  final List<Map<String, Object?>> finds = <Map<String, Object?>>[];
  final List<Object> findResults = <Object>[];
  final List<SaleReturnPreviewRequest> previews = <SaleReturnPreviewRequest>[];
  final List<Object> previewResults = <Object>[];
  final List<SaleReturnDraft> submits = <SaleReturnDraft>[];
  final List<Object> submitResults = <Object>[];
  int _keys = 0;

  String nextKey() {
    _keys += 1;
    return '00000000-0000-4000-8000-${_keys.toString().padLeft(12, '0')}';
  }

  Future<SaleReturnPreview> preview(SaleReturnPreviewRequest request) async {
    previews.add(request);
    final Object result = previewResults.isEmpty
        ? answerNormally
        : previewResults.removeAt(0);
    if (result is Completer<SaleReturnPreview>) return result.future;
    if (identical(result, answerNormally)) {
      return SaleReturnPreview.fromCallable(
        returnPreviewJsonFor(request),
        request: request,
      );
    }
    throw result;
  }

  Future<SaleReturnReceipt> submit(SaleReturnDraft draft) async {
    final Object result = submitResults.isEmpty
        ? answerNormally
        : submitResults.removeAt(0);
    // Like the shell, a session refusal happens before the draft is stored.
    if (result is SaleSessionException) throw result;
    final SaleCorrectionDraft? current = unresolved;
    if (current != null && current != draft) {
      throw const CorrectionUnresolvedException();
    }
    unresolved = draft;
    submits.add(draft);
    try {
      final SaleReturnReceipt receipt;
      if (result is Completer<SaleReturnReceipt>) {
        receipt = await result.future;
      } else if (identical(result, answerNormally) ||
          identical(result, answerReplayed)) {
        receipt = SaleReturnReceipt.fromCallable(
          returnResponseFor(draft, replayed: identical(result, answerReplayed)),
          draft: draft,
        );
      } else {
        throw result;
      }
      unresolved = null;
      return receipt;
    } on SaleRejectedException {
      unresolved = null;
      rethrow;
    }
  }

  Future<CorrectableSale> find(SaleLookupQuery query) async {
    finds.add(query.toRequest());
    final Object result = findResults.isEmpty
        ? lookupSale()
        : findResults.removeAt(0);
    if (result is CorrectableSale) return result;
    if (result is Completer<CorrectableSale>) return result.future;
    throw result;
  }

  SaleCorrections get corrections => SaleCorrections(
    branchId: saleBranchId,
    find: find,
    listRecent: () async => RecentCorrectableSales.fromCallable(
      <String, Object?>{'sales': <Object?>[]},
      query: RecentSalesQuery(),
    ),
    previewReturn: preview,
    submitReturn: submit,
    unresolvedDraft: () => unresolved,
    createKey: nextKey,
  );
}
