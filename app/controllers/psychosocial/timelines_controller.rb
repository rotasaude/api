# Linha do tempo restrita do CAPS (ADR 0049; contrato §10, P18):
#   GET /psychosocial/enrollments/:id/timeline?before=&limit=
#     → { items: [<entry do profissional>], next_before }
# Só a equipe lotada no CAPS da matrícula (outro CAPS ou id malformado → 404;
# sem o papel do CAPS → 403 missing_role). Traz a fonte do CAPS
# (Query::CAPS_ONLY_KINDS, recortada por este CAPS) e o marcador do vínculo,
# no cursor da linha do tempo; toda leitura grava a trilha `timeline`. Na
# query só `before` e `limit`.
module Psychosocial
  class TimelinesController < BaseController
    KINDS = (Timeline::Query::CAPS_ONLY_KINDS + Timeline::Query::LINK_KINDS).freeze

    def show
      return forbid unless Access.staff?(Current.user)
      return unless query_only!("before", "limit")

      enrollment = uuid?(params[:id]) ? PsychosocialEnrollment.find_by(id: params[:id]) : nil
      return not_found unless enrollment && Access.can_read?(Current.user, enrollment)

      query = request.query_parameters
      page = Timeline::Query.call(person: Timeline::Person.for_patient(enrollment.patient), kinds: KINDS,
                                  before: Timeline::Cursor.decode(query["before"]), limit: Timeline::Query.limit(query["limit"]),
                                  psychosocial_unit_id: enrollment.health_unit_id)
      Trail.viewed!(patient: enrollment.patient_id, user: Current.user, resource: "timeline")
      render json: { items: page.entries.map { |entry| Timeline::Json.professional(entry) }, next_before: page.next_before }
    rescue Timeline::Cursor::Invalid
      render_refusal("before", "invalid_cursor")
    end
  end
end
