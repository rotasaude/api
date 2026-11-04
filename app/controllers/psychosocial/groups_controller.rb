# Grade semanal de grupos do CAPS (ADR 0049; contrato §4, P12, P13, P25):
#   GET   /psychosocial/groups?health_unit_id[&active=true|false]  { items }, por dia, hora e nome; sem trilha
#   POST  /psychosocial/groups        → 201 <grupo> (psychosocial_staff lotado; sem step-up)
#   PATCH /psychosocial/groups/:id    → <grupo>
# Grupo de outro CAPS (ou de CAPS onde quem pede não está lotado) → 404. Sem
# dado do paciente; ids na URL, o resto no corpo.
module Psychosocial
  class GroupsController < BaseController
    ACTIVE = { "true" => true, "false" => false }.freeze

    def index
      return unless query_only!("health_unit_id", "active")

      query = request.query_parameters
      unit = staff_unit!(query["health_unit_id"])
      return unless unit
      return render_refusal("active") if query.key?("active") && !ACTIVE.key?(query["active"])

      scope = PsychosocialGroup.where(health_unit_id: unit.id).includes(responsible_user: :professional)
      scope = scope.where(active: ACTIVE.fetch(query["active"])) if query.key?("active")
      rows = scope.order(:weekday, :starts_at, :name, :id).to_a
      cbos = Access.cbos(rows.map(&:responsible_user_id), unit.id)
      render json: { items: rows.map { |group| Json.group(group, cbos: cbos) } }
    end

    def create
      return unless query_only!

      unit = staff_unit!(body_param("health_unit_id"))
      return unless unit

      result = SaveGroup.call(attrs: body, by: Current.user)
      return render_failure(result) if result.failure?

      render json: detail(result.payload.fetch(:group)), status: :created
    end

    def update
      return forbid unless Access.staff?(Current.user)
      return unless query_only!

      group = uuid?(params[:id]) ? PsychosocialGroup.find_by(id: params[:id]) : nil
      return not_found unless group && Access.can_read?(Current.user, group)

      result = SaveGroup.call(attrs: body, by: Current.user, group: group)
      return render_failure(result) if result.failure?

      render json: detail(result.payload.fetch(:group))
    end

    private

    def detail(group) = Json.group(group, cbos: Access.cbos([ group.responsible_user_id ], group.health_unit_id))
  end
end
