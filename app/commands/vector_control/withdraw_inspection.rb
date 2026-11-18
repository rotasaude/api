# Efeitos da retirada da visita sobre o boletim (módulo 35a, ADR 0054;
# contrato §3; plano, W-5, W-13, Review Focus 4). A inspeção fica (só
# acréscimo), marcada pela visita retirada; o resto volta, na transação do
# HomeVisits::Withdraw:
#   - lock! (antes da folha): perfil FOR UPDATE, item do LIRAa FOR UPDATE e
#     o levantamento dele FOR SHARE, na ordem do registro (perfil → item →
#     levantamento → folha → visita; RecordInspection#liraa_item), para a
#     retirada e o registro no mesmo imóvel não se travarem. O fechamento
#     (Liraa::Close, FOR UPDATE no levantamento) espera a retirada em curso, e
#     a decisão de devolver o item usa o estado lido sob a trava;
#   - call (depois do update! da visita): o perfil volta à inspeção válida
#     anterior (ou fica sem last_*), com version + 1 e
#     household_vector_profile.changed; o quarteirão e o risco ficam (Q20(2):
#     a retirada desfaz só o que é da visita); o item volta a pending
#     (Liraa::Items.released!) quando a inspeção retirada é das que o mudaram
#     e nenhuma outra válida que o muda o usa (o substituto, inspecionado ou
#     não, fica como está, W-13). Levantamento já fechado: o item fica (o
#     trigger não deixa mudá-lo) e a retirada passa assim mesmo (a inspeção
#     fica marcada pela visita retirada; o Liraa::Index do fechado segue
#     congelado em closed_at).
#   - o estorno (Task 7; A-1, W-5, W-6): cada `vector_application` das
#     medidas ganha um `vector_application_reversal` (positivo) no mesmo lote e
#     local, uma vez (medida já estornada fica; a segunda retirada nem chega
#     aqui: 409 visit_changed); a falta aberta da medida é conciliada pelo
#     sistema (`reconciled_at`, sem usuário nem nota). Trava lotes → local →
#     falta, depois da visita (a ordem do registro). O local desativado depois
#     da baixa recebe o estorno assim mesmo: a retirada nunca é recusada por
#     estoque.
module VectorControl
  module WithdrawInspection
    module_function

    # -> [perfil | nil, item | nil, status do levantamento | nil] travados
    # (nada sem inspeção).
    def lock!(visit)
      inspection = VectorInspection.find_by(home_visit_id: visit.id)
      return [ nil, nil, nil ] unless inspection

      profile = HouseholdVectorProfile.lock.find_by(household_id: inspection.household_id)
      item = inspection.liraa_draw_item_id && LiraaDrawItem.lock.find_by(id: inspection.liraa_draw_item_id)
      survey_status = item && LiraaSurvey.joins(:strata).where(liraa_strata: { id: item.liraa_stratum_id })
                                         .lock("FOR SHARE OF liraa_surveys").pick(:status)
      [ profile, item, survey_status ]
    end

    # -> VectorInspection | nil. A visita já está retirada (update! antes).
    def call(visit, by:)
      inspection = VectorInspection.find_by(home_visit_id: visit.id)
      return nil unless inspection

      profile, item, survey_status = lock!(visit)
      reverse_stock!(inspection, by)
      Liraa::Items.released!(item, survey_status: survey_status) if item && releases?(inspection, item)
      SaveProfile.write!(profile, RecordInspection.last_attributes(inspection.household_id), by, created: false) if profile
      inspection
    end

    def reverse_stock!(inspection, by, now: Time.current)
      measures = VectorInspectionMeasure.where(vector_inspection_id: inspection.id).where.not(vector_product_id: nil).index_by(&:id)
      return if measures.empty?

      applied = StockMovement.where(vector_inspection_measure_id: measures.keys, kind: "vector_application").order(:id).to_a
      reversed = StockMovement.where(vector_inspection_measure_id: measures.keys, kind: "vector_application_reversal")
                              .pluck(:vector_inspection_measure_id).to_set
      pending = applied.reject { |movement| reversed.include?(movement.vector_inspection_measure_id) }
      if pending.any?
        lots = Pharmacy::Ledger.lock_lots!(pending.map(&:stock_lot_id))
        locations = pending.map(&:stock_location_id).uniq.sort.to_h { |id| [ id, StockLocation.lock("FOR SHARE").find(id) ] }
        pending.each do |movement|
          Pharmacy::Ledger.record!(location: locations.fetch(movement.stock_location_id), lot: lots.fetch(movement.stock_lot_id),
                                   kind: "vector_application_reversal", quantity: -movement.quantity, by: by,
                                   document: measures.fetch(movement.vector_inspection_measure_id), at: now)
        end
      end
      VectorStockShortfall.where(vector_inspection_measure_id: measures.keys, reconciled_at: nil).order(:id).lock.each do |shortfall|
        shortfall.update!(reconciled_at: now, version: shortfall.version + 1)
      end
    end

    def releases?(inspection, item)
      moving = Liraa::Items::MOVING_SITUATIONS
      moving.include?(inspection.situation) &&
        !VectorInspection.valid_inspections.where(liraa_draw_item_id: item.id, situation: moving).exists?
    end
    private_class_method :reverse_stock!, :releases?
  end
end
