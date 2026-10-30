# Associação da eSB (71) à eSF/eAP da população (ADR 0046; Desvio 13, D7;
# contrato §16 O11). O Cnes::Apply liga sozinho quando a unidade tem uma só
# eSF/eAP ativa; nos outros casos, o admin escolhe. Candidata = equipe 70/76
# ativa da mesma unidade; senão 422 `invalid_request` em `associated_team_id`.
# Evento `dental.team_association_changed` só com ids.
module DentalCare
  module AssociateTeam
    PATH = "associated_team_id".freeze

    module_function

    # team: eSB ativa (o controller garante). -> Result.ok(team:) | fail(:invalid_request, details: { path:, problems: })
    def call(team:, params:, by:)
      id = params[PATH]
      return refuse unless id.is_a?(String)

      HealthTeam.transaction(requires_new: true) do
        candidate = candidates(team).lock("FOR SHARE").find_by(id: id)
        next refuse unless candidate

        team.lock!.update!(associated_team: candidate)
        DomainEvents.publish("dental.team_association_changed", team_id: team.id, user_id: by.id)
        Result.ok(team: team)
      end
    end

    # As eSF/eAP ativas da unidade da eSB.
    def candidates(team) = HealthTeam.where(health_unit_id: team.health_unit_id, active: true, kind: HealthTeam::PRIMARY_CARE_KINDS)

    def refuse = Result.fail(:invalid_request, details: { path: PATH, problems: [ { path: PATH, error: "invalid_request" } ] })
    private_class_method :refuse
  end
end
