# Atribui microárea a um CBO de campo (módulo 24b, ADR 0052; contrato §1, §6;
# 6A; ruling A3). Quem chama já conferiu que `by` é o enfermeiro da equipe da
# microárea (HomeVisits::Access.assigner?) e o step-up. Aqui:
#   - microárea ativa (422 micro_area_inactive);
#   - o profissional com vínculo ativo NA EQUIPE da microárea cujo CBO é da
#     Tabela 7 e não é o 515105: o ACS nunca é atribuído (A3; nem à própria,
#     de que já é responsável, nem à do colega) → 422 cbo_not_allowed;
#   - uma atribuição ativa por (microárea, profissional) → 409 already_assigned
#     (o índice único parcial decide a corrida).
# Evento micro_area.field_assignment_changed só com ids.
module HomeVisits
  module AssignMicroArea
    module_function

    def call(micro_area:, professional_id:, by:)
      return Result.fail(:micro_area_inactive) unless micro_area.active

      member = HealthTeamMember.active.includes(:professional).find_by(professional_id: professional_id, health_team_id: micro_area.team_id)
      return Result.fail(:cbo_not_allowed) unless assignable?(member)
      return Result.fail(:already_assigned) if MicroAreaFieldAssignment.active.exists?(micro_area: micro_area, professional_id: professional_id)

      assignment = MicroAreaFieldAssignment.transaction(requires_new: true) do
        MicroAreaFieldAssignment.create!(micro_area: micro_area, professional: member.professional, assigned_by_user: by).tap do |row|
          DomainEvents.publish("micro_area.field_assignment_changed", micro_area_id: micro_area.id, professional_id: row.professional_id,
                                                                     user_id: by.id, ended: false)
        end
      end
      Result.ok(assignment: assignment, cbo: member.cbo_code)
    rescue ActiveRecord::RecordNotUnique
      Result.fail(:already_assigned)
    end

    def assignable?(member)
      cbo = member&.cbo_code.to_s
      cbo != Catalog::ACS_CBO && Catalog::HOME_VISIT_CBOS.include?(cbo)
    end
    private_class_method :assignable?
  end
end
