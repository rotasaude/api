# GET /urgency/counter_referrals?health_unit_id= (contrato §7 e §14 Q11,
# Q20): "Retornos pedidos pela urgência" da UBS, pelo
# Urgency::CounterReferrals → `{ items }`, sem o motivo e sem trilha. Leem a
# recepção (citizen_verifier) e o health_professional com vínculo ativo NA
# unidade (senão missing_role | missing_link). Só o id da unidade na query.
module Urgency
  class CounterReferralsController < BaseController
    def index
      return unless query_only!("health_unit_id")

      unit_id = params[:health_unit_id]
      unit = uuid?(unit_id) ? HealthUnit.find_by(id: unit_id) : nil
      return not_found unless unit
      return forbid(refusal) unless Access.reception?(Current.user) || linked?(unit)

      render json: { items: CounterReferrals.for(unit: unit) }
    end

    private

    def linked?(unit)
      Current.user.has_role?("health_professional") &&
        ProfessionalLink.active.joins(:professional).exists?(professionals: { user_id: Current.user.id }, health_unit_id: unit.id)
    end

    def refusal = Current.user.has_role?("health_professional") ? "missing_link" : "missing_role"
  end
end
