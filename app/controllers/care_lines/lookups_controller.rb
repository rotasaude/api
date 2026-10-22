# Listas de apoio do dashboard (Divergência L10): linhas ativas (nome e se
# pede DUM) e equipes visíveis para os filtros, com can_confirm (§11 T2).
# Profissional sem vínculo ativo: 403 missing_role (P5f).
module CareLines
  class LookupsController < BaseController
    before_action { forbid unless Access.preview?(Current.user) || Access.professional_unit_ids(Current.user).any? }

    def lines = render(json: { lines: CareLine.active_lines.order(:name, :id).map { |l| Json.line_summary(l) } })

    def teams
      confirm = Access.confirm_unit_ids(Current.user)
      render json: { teams: Access.visible_teams(Current.user).map { |t| Json.team(t).merge(can_confirm: confirm.include?(t.health_unit_id)) } }
    end
  end
end
