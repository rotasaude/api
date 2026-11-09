# GET /urgency/provisional_encounters?health_unit_id= (contrato §14 Q25,
# Q29): os provisórios ainda não identificados da UPA, abertos ou fechados
# nos últimos 7 dias, pelo Urgency::ProvisionalEncounters → `{ items }`. Só a
# recepção (citizen_verifier) lê, porque só ela identifica (§4): a
# enfermagem e o médico já veem o provisório na fila e no detalhe, e a lista
# levaria a descrição física de todos sem necessidade (os demais → 403
# missing_role). Só o id da unidade na query (§13; cpf/cns/name → 422 com o
# nome da chave); sem ele → 422 invalid_request `health_unit_id`; malformado
# ou inexistente → 404; CAPS → caps_unit_not_allowed (P32 do 31) antes de não
# UPA → not_an_upa. A lista leva a descrição: uma trilha por paciente listado
# (resource provisional_encounters), como os candidatos do duplicado (Q23).
module Urgency
  class ProvisionalEncountersController < BaseController
    def index
      return unless require_reception!
      return unless query_only!("health_unit_id")

      unit_id = request.query_parameters["health_unit_id"]
      return render_refusal("health_unit_id") if unit_id.blank?

      unit = uuid?(unit_id) ? HealthUnit.find_by(id: unit_id) : nil
      return not_found unless unit
      return render(json: { error: "caps_unit_not_allowed" }, status: :unprocessable_entity) if unit.caps?
      return render(json: { error: "not_an_upa" }, status: :unprocessable_entity) unless unit.upa?

      items = ProvisionalEncounters.for(unit: unit)
      items.each { |item| Trail.viewed!(user: Current.user, patient_id: item[:patient][:patient_id], resource: "provisional_encounters") }
      render json: { items: items }
    end
  end
end
