# Efeitos da retirada da visita sobre o boletim (módulo 35a, ADR 0054;
# contrato §3; plano, W-5, W-13, Review Focus 4). A inspeção fica (só
# acréscimo), marcada pela visita retirada; o resto volta, na transação do
# HomeVisits::Withdraw:
#   - lock! (antes da folha): perfil FOR UPDATE e item do LIRAa FOR UPDATE,
#     na ordem do registro (perfil → item → folha → visita), para a retirada
#     e o registro no mesmo imóvel não se travarem;
#   - call (depois do update! da visita): o perfil volta à inspeção válida
#     anterior (ou fica sem last_*), com version + 1 e
#     household_vector_profile.changed; o quarteirão e o risco ficam (Q20(2):
#     a retirada desfaz só o que é da visita); o item volta a pending
#     (Liraa::Items.released!) quando a inspeção retirada é das que o mudaram
#     e nenhuma outra válida que o muda o usa (o substituto, inspecionado ou
#     não, fica como está, W-13).
# O estorno da baixa de estoque entra na Task 7 (marcado abaixo).
module VectorControl
  module WithdrawInspection
    module_function

    # -> [perfil | nil, item | nil] travados (nada sem inspeção).
    def lock!(visit)
      inspection = VectorInspection.find_by(home_visit_id: visit.id)
      return [ nil, nil ] unless inspection

      profile = HouseholdVectorProfile.lock.find_by(household_id: inspection.household_id)
      item = inspection.liraa_draw_item_id && LiraaDrawItem.lock.find_by(id: inspection.liraa_draw_item_id)
      [ profile, item ]
    end

    # -> VectorInspection | nil. A visita já está retirada (update! antes).
    def call(visit, by:)
      inspection = VectorInspection.find_by(home_visit_id: visit.id)
      return nil unless inspection

      profile, item = lock!(visit)
      # Task 7: o estorno das baixas das medidas (vector_application_reversal) e
      # a conciliação das faltas pelo sistema entram aqui.
      Liraa::Items.released!(item) if item && releases?(inspection, item)
      SaveProfile.write!(profile, RecordInspection.last_attributes(inspection.household_id), by, created: false) if profile
      inspection
    end

    def releases?(inspection, item)
      moving = Liraa::Items::MOVING_SITUATIONS
      moving.include?(inspection.situation) &&
        !VectorInspection.valid_inspections.where(liraa_draw_item_id: item.id, situation: moving).exists?
    end
    private_class_method :releases?
  end
end
