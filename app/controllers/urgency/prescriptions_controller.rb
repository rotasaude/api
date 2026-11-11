# Prescrição interna da UPA (ADR 0050; contrato §5 e §12 P1, Q4, Q6).
#
# POST /urgency/encounters/:id/prescriptions { items: [...], expected_active_id? }
# → 201 `{ prescription }` pelo Urgency::IssuePrescription (emite a v1 ou, com uma
# ativa, a versão seguinte; Q16: `expected_active_id` null/id confere o que a tela
# viu → 409 prescription_changed; sem a chave, a regra antiga). O catálogo (plataforma) é lido AQUI, fora da
# transação da cidade: `MedicationCatalogItem.prescribable.where(id:)`.
# POST /urgency/prescriptions/:id/suspend { reason } → 200 `{ prescription }`
# pelo Urgency::SuspendPrescription. Os dois só do corpo (chave desconhecida →
# 422 com o nome da chave); só o médico da UPA do encontro.
module Urgency
  class PrescriptionsController < BaseController
    ISSUE_KEYS = %w[items expected_active_id].freeze
    SUSPEND_KEYS = %w[reason].freeze

    def create
      return unless query_only! && only_keys!(ISSUE_KEYS)

      encounter = find_encounter(params[:id])
      return unless encounter

      items = body_param("items")
      catalog = prescribable(items)
      expected = request.request_parameters.key?("expected_active_id") ? body_param("expected_active_id") : IssuePrescription::ABSENT
      result = IssuePrescription.call(encounter: encounter, items: items, catalog: catalog, by: Current.user, expected_active_id: expected)
      return render_failure(result) if result.failure?

      render_prescription(result.payload.fetch(:prescription), status: :created)
    end

    def suspend
      return unless query_only! && only_keys!(SUSPEND_KEYS)

      prescription = uuid?(params[:id]) ? UrgencyPrescription.find_by(id: params[:id]) : nil
      return not_found unless prescription

      result = SuspendPrescription.call(prescription: prescription, reason: body_param("reason"), by: Current.user)
      return render_failure(result) if result.failure?

      render_prescription(result.payload.fetch(:prescription))
    end

    private

    # { id => MedicationCatalogItem } dos ids bem formados do corpo.
    def prescribable(items)
      ids = Array(items).filter_map { |row| row["catalog_item_id"].downcase if row.is_a?(Hash) && Input.uuid?(row["catalog_item_id"]) }
      ids.empty? ? {} : MedicationCatalogItem.prescribable.where(id: ids.uniq).index_by(&:id)
    end

    def render_prescription(prescription, status: :ok)
      prescription = UrgencyPrescription.includes(:items, prescribed_by_user: :professional).find(prescription.id)
      render json: { prescription: PrescriptionJson.call(prescription, catalog: PrescriptionJson.catalog_for(prescription)) }, status: status
    end
  end
end
