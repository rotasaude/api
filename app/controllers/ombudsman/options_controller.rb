# GET /ombudsman/options (ADR 0051; contrato §16 Q7): o que as telas escolhem —
# só linhas ativas. Assuntos com subassuntos; unidades e setores com
# `has_active_responder` (Access: linha ativa, papel e conta ativos);
# profissionais com vínculo ativo, com as unidades ativas em que atuam.
# Técnico e ouvidor. Sem dado de pessoa além do nome do profissional.
module Ombudsman
  class OptionsController < BaseController
    before_action :require_staff!
    before_action :query_only!

    def show
      Settings.ensure_defaults!
      covered = Access.destinations_with_responder
      units = HealthUnit.active_units.to_a
      render json: {
        subjects: subjects, departments: departments(covered[:department_ids]),
        health_units: units.map { |u| { id: u.id, name: u.name, kind: u.kind, has_active_responder: covered[:health_unit_ids].include?(u.id) } },
        professionals: professionals(units.map(&:id))
      }
    end

    private

    def subjects
      OmbudsmanSubject.active.includes(:children).where(parent_id: nil).order(:position, :name).map do |subject|
        { id: subject.id, name: subject.name,
          children: subject.children.select(&:active).map { |child| { id: child.id, name: child.name } } }
      end
    end

    def departments(covered_ids)
      Department.active.order(:name, :id).map { |d| { id: d.id, name: d.name, has_active_responder: covered_ids.include?(d.id) } }
    end

    def professionals(unit_ids)
      units_by_professional = ProfessionalLink.active.where(health_unit_id: unit_ids).pluck(:professional_id, :health_unit_id)
                                              .group_by(&:first).transform_values { |pairs| pairs.map(&:last).uniq.sort }
      Professional.where(id: units_by_professional.keys).joins(:user).where(users: { deactivated_at: nil })
                  .order(:professional_name, :id).map do |professional|
        { id: professional.id, name: professional.professional_name, health_unit_ids: units_by_professional.fetch(professional.id) }
      end
    end
  end
end
