# Matriciamento do CAPS com a atenção básica (ADR 0049; contrato §7, P4, P12, P23):
#   POST /psychosocial/matrix_supports { health_unit_id, health_team_id, held_on, topic,
#                                        participants_user_ids, sigtap_code }
#        → 201 <detalhe> (sem casos), sem trilha (sem paciente); a crítica da
#        ação BPA-C recusa com 422 { error: "action_rejected", problems: [ { error, path } ] }
#   GET  /psychosocial/matrix_supports?health_unit_id&before
#        lista do CAPS, sem texto (nem tema, nem caso) e sem trilha, da mais
#        nova para a mais antiga (created_at, id), em páginas de PAGE, com `next_before`
#   GET  /psychosocial/matrix_supports/:id
#        <detalhe> com o tema e os casos; trilha `resource: "matrix_support"` por paciente dos casos
#   POST /psychosocial/matrix_supports/:id/cases { patient_id, shared_text }
#        → 201 o caso, sem trilha (quem grava digitou)
# Só a equipe lotada no CAPS do matriciamento; de outro CAPS (ou de CAPS onde
# quem pede não está lotado) → 404. Texto e paciente só no corpo; ids na URL.
module Psychosocial
  class MatrixSupportsController < BaseController
    PAGE = 200

    before_action :load_support, only: %i[show add_case]

    def index
      return unless query_only!("health_unit_id", "before")

      unit = staff_unit!(request.query_parameters["health_unit_id"])
      return unless unit

      scope = PsychosocialMatrixSupport.where(health_unit_id: unit.id)
      if request.query_parameters.key?("before")
        at, id = CareRegulation::Cursor.decode_page(request.query_parameters["before"])
        scope = scope.where("(psychosocial_matrix_supports.created_at, psychosocial_matrix_supports.id) < (?, ?)", at, id)
      end
      rows = scope.includes(:health_team).order(created_at: :desc, id: :desc).limit(PAGE + 1).to_a
      page = rows.first(PAGE)
      counts = PsychosocialMatrixCase.where(psychosocial_matrix_support_id: page.map(&:id)).group(:psychosocial_matrix_support_id).count
      people = participants(page, unit.id)
      cache = Billing::SigtapCache.new
      render json: { items: page.map { |support| item(support, people, counts.fetch(support.id, 0), cache) },
                     next_before: rows.size > PAGE ? CareRegulation::Cursor.encode_page(page.last.created_at, page.last.id) : nil }
    rescue CareRegulation::Cursor::Invalid
      render_refusal("before", "invalid_cursor")
    end

    def show
      cases = @support.psychosocial_matrix_cases.includes(:patient).order(:created_at, :id).to_a
      cases.map(&:patient_id).uniq.each { |patient_id| Trail.viewed!(patient: patient_id, user: Current.user, resource: "matrix_support") }
      render json: detail(@support, cases)
    end

    def create
      return unless query_only!

      unit = staff_unit!(body_param("health_unit_id"))
      return unless unit

      result = RecordMatrixSupport.call(attrs: body, unit: unit, by: Current.user, link: @link)
      return render_failure(result) if result.failure?

      render json: detail(result.payload.fetch(:matrix_support), []), status: :created
    end

    def add_case
      result = AddMatrixCase.call(support: @support, attrs: body, by: Current.user)
      return render_failure(result) if result.failure?

      render json: case_json(result.payload.fetch(:matrix_case)), status: :created
    end

    private

    # O matriciamento da URL: sem o papel do CAPS → 403 missing_role; id
    # malformado, inexistente ou de CAPS em que quem pede não está lotado → 404.
    def load_support
      return forbid unless Access.staff?(Current.user)
      return unless query_only!

      @support = uuid?(params[:id]) ? PsychosocialMatrixSupport.includes(:health_team).find_by(id: params[:id].downcase) : nil
      not_found unless @support && Access.can_read?(Current.user, @support)
    end

    # { user_id => <pro> } dos participantes, com o CBO do vínculo no CAPS.
    def participants(supports, health_unit_id)
      ids = supports.flat_map(&:participant_user_ids).uniq
      cbos = Access.cbos(ids, health_unit_id)
      User.where(id: ids).includes(:professional).to_h { |user| [ user.id, Json.pro(user, cbos[user.id]) ] }
    end

    # Na lista: sem tema nem caso (P4), só a contagem de casos.
    def item(support, people, cases_count, cache)
      { "id" => support.id, "health_unit_id" => support.health_unit_id, "health_team" => team_json(support.health_team),
        "held_on" => Json.date(support.held_on), "participants" => support.participant_user_ids.filter_map { |id| people[id] },
        "sigtap" => Json.sigtap(support.sigtap_code, "bpa_c", support.held_on, cache: cache),
        "action_id" => support.psychosocial_action_id, "cases_count" => cases_count, "created_at" => Json.time(support.created_at) }
    end

    def detail(support, cases)
      item(support, participants([ support ], support.health_unit_id), cases.size, Billing::SigtapCache.new)
        .merge("topic" => support.topic, "cases" => cases.map { |matrix_case| case_json(matrix_case) })
    end

    def case_json(matrix_case)
      { "id" => matrix_case.id, "patient" => Json.patient_ref(matrix_case.patient), "shared_text" => matrix_case.shared_text,
        "created_at" => Json.time(matrix_case.created_at) }
    end

    def team_json(team)
      { "id" => team.id, "name" => team.name, "ine" => team.ine, "health_unit_id" => team.health_unit_id }
    end
  end
end
