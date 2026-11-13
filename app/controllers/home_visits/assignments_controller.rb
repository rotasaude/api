# /home_visits/assignments (contrato §6; 6A; Q21; ruling A3): só o enfermeiro
# da equipe lê, atribui e encerra; escrita com step-up. Fora da equipe → 403
# out_of_scope; membro que não é enfermeiro → 403 cbo_not_allowed; atribuição
# de outra equipe por id → 404. O cbo_not_allowed do profissional atribuído
# (fora da Tabela 7, ou o ACS) é 422 (Desvio 11). Sem trilha: nenhum dado de
# cidadão.
module HomeVisits
  class AssignmentsController < BaseController
    ASSIGNEE_STATUS = { cbo_not_allowed: :unprocessable_entity }.freeze

    # create e end_assignment não leem a query (ids no corpo e no caminho): recusa antes do step-up.
    before_action(only: %i[create end_assignment]) { query_only! }
    before_action :require_step_up!, only: %i[create end_assignment]

    def index
      return unless query_only!(:team_id)
      return unless load_team! && nurse!(@team)

      rows = MicroAreaFieldAssignment.active.joins(:micro_area).where(micro_areas: { team_id: @team.id })
                                     .includes(:micro_area, :professional, assigned_by_user: :professional)
                                     .order("micro_areas.code", :created_at, :id).to_a
      cbos = active_cbos(@team, rows.map(&:professional_id))
      candidates = HealthTeamMember.active.includes(:professional)
                                   .where(health_team: @team, cbo_code: (Catalog::HOME_VISIT_CBOS.to_a - [ Catalog::ACS_CBO ]))
                                   .sort_by { |member| [ member.professional.professional_name, member.professional_id ] }
      render json: { items: rows.map { |row| Json.assignment(row, cbo: cbos[row.professional_id]) },
                     candidates: candidates.map { |member| Json.candidate(member) } }
    end

    def create
      micro_area_id = body_param("micro_area_id")
      professional_id = body_param("professional_id")
      return render_refusal("invalid_request", path: "micro_area_id") unless uuid?(micro_area_id)
      return render_refusal("invalid_request", path: "professional_id") unless uuid?(professional_id)

      area = MicroArea.includes(:team).find_by(id: micro_area_id)
      return render_refusal("not_found") unless area
      return render_refusal("out_of_scope") unless Access.member(Current.user, area.team)
      return unless nurse!(area.team)

      result = AssignMicroArea.call(micro_area: area, professional_id: professional_id, by: Current.user)
      return render_failure(result, status: ASSIGNEE_STATUS) if result.failure?

      render json: Json.assignment(result.payload[:assignment], cbo: result.payload[:cbo]), status: :created
    end

    def end_assignment
      assignment = uuid?(params[:id]) && MicroAreaFieldAssignment.includes(micro_area: :team).find_by(id: params[:id])
      return render_refusal("not_found") unless assignment && Access.assigner?(Current.user, assignment.micro_area.team)

      result = EndAssignment.call(assignment: assignment, by: Current.user)
      return render_failure(result) if result.failure?

      row = result.payload[:assignment]
      render json: Json.assignment(row, cbo: active_cbos(row.micro_area.team, [ row.professional_id ])[row.professional_id])
    end

    private

    # Membro da equipe que não é o enfermeiro → 403 cbo_not_allowed (false).
    def nurse!(team)
      return true if Access.assigner?(Current.user, team)

      render_refusal("cbo_not_allowed")
      false
    end

    # { professional_id => CBO do vínculo ativo na equipe }.
    def active_cbos(team, professional_ids)
      HealthTeamMember.active.where(health_team: team, professional_id: professional_ids).pluck(:professional_id, :cbo_code).to_h
    end
  end
end
