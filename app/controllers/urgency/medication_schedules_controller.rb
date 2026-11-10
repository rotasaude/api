# GET /urgency/encounters/:id/medication_schedule (ADR 0050; contrato §5 e §12
# Q2, Q5): o aprazamento da prescrição ativa (Urgency::Schedule), calculado na
# leitura. Lê quem checa a medicação na UPA do atendimento (2235*, 3222*,
# 225*); a recepção e quem perdeu o vínculo → 403 (Access.refusal), nunca 404.
# Grava a trilha `medication_schedule` (Desvio 11). Nada na query. O catálogo e
# o interruptor de estoque (plataforma) são lidos AQUI, fora da transação da
# cidade; `stock_deduction` utilizável acrescenta os lotes FEFO do local `unit`.
module Urgency
  class MedicationSchedulesController < BaseController
    def show
      return unless query_only!

      encounter = find_encounter(params[:id])
      return unless encounter

      unit_id = encounter.attendance.health_unit_id
      return forbid(Access.refusal(Current.user, unit_id).to_s) unless Access.nursing_or_physician_link(Current.user, unit_id)

      deduction = StockGate.usable?(Current.city)
      prescription = encounter.active_prescription
      catalog = prescription ? PrescriptionJson.catalog_for(prescription) : {}
      stock = deduction ? { location: Fefo.location_for(unit_id), today: Time.zone.today } : nil

      Trail.viewed!(user: Current.user, patient_id: encounter.patient.id, resource: "medication_schedule")
      render json: Schedule.call(encounter, now: Time.current, catalog: catalog, stock: stock).merge(stock_deduction: deduction)
    end
  end
end
