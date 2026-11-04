# Revisão do PTS vencida (ADR 0049; contrato P16, D9): vale só a versão mais
# nova de cada matrícula ABERTA. Vencida = `review_on` antes de hoje; a
# matrícula sem PTS vence quando começou há mais de `care_plan_review_days`
# (parâmetro do CAPS). Lida pela rota `care_plans/due` e pelo job diário.
module Psychosocial
  module CarePlanReview
    module_function

    # { enrollment_id => { plan_id:, review_on: } } da versão mais nova de cada
    # matrícula do recorte (uma relação de PsychosocialEnrollment).
    def latest(enrollments)
      PsychosocialCarePlan.where(psychosocial_enrollment_id: enrollments.select(:id))
                          .order(:psychosocial_enrollment_id, version: :desc)
                          .pluck(Arel.sql("DISTINCT ON (psychosocial_enrollment_id) psychosocial_enrollment_id, id, review_on"))
                          .to_h { |enrollment_id, id, review_on| [ enrollment_id, { plan_id: id, review_on: review_on } ] }
    end

    # Matrículas abertas do CAPS com a revisão vencida, as mais atrasadas
    # primeiro; user: só as do técnico de referência (nil = todas).
    # -> [[PsychosocialEnrollment, review_on | nil]]
    def due(unit:, today:, user: nil)
      scope = PsychosocialEnrollment.open_enrollments.where(health_unit_id: unit.id)
      scope = scope.where(reference_user_id: user.id) if user
      days = Settings.current.care_plan_review_days
      latest = latest(scope)
      scope.includes(:patient).to_a.filter_map do |enrollment|
        review_on = latest.dig(enrollment.id, :review_on)
        due_on = review_on || enrollment.started_on + days
        [ enrollment, review_on, due_on ] if review_on ? review_on < today : enrollment.started_on < today - days
      end.sort_by { |enrollment, _, due_on| [ due_on, enrollment.id ] }.map { |enrollment, review_on, _| [ enrollment, review_on ] }
    end

    # Quantas matrículas abertas dos CAPS `units` estão com a revisão vencida:
    # a MESMA regra de `due` (versão mais nova com `review_on` antes de hoje; sem
    # PTS, início antes de hoje − care_plan_review_days), numa contagem SQL só —
    # não carrega matrícula nem paciente (o painel, Task 15).
    def overdue_count(units:, today:)
      cutoff = today - Settings.current.care_plan_review_days
      PsychosocialEnrollment.open_enrollments.where(health_unit_id: units.map(&:id))
                            .joins(<<~SQL.squish)
                              LEFT JOIN LATERAL (SELECT p.review_on FROM psychosocial_care_plans p
                                                  WHERE p.psychosocial_enrollment_id = psychosocial_enrollments.id
                                                  ORDER BY p.version DESC LIMIT 1) latest ON TRUE
                            SQL
                            .where("(latest.review_on IS NOT NULL AND latest.review_on < :today) OR " \
                                   "(latest.review_on IS NULL AND psychosocial_enrollments.started_on < :cutoff)", today: today, cutoff: cutoff)
                            .count
    end

    # Ids das versões vencidas (a mais nova de cada matrícula aberta da
    # cidade) que ainda não têm aviso.
    def unalerted_overdue_plan_ids(today:)
      ids = latest(PsychosocialEnrollment.open_enrollments).values.filter_map { |plan| plan[:plan_id] if plan[:review_on] < today }
      ids - PsychosocialCarePlanAlert.where(psychosocial_care_plan_id: ids).pluck(:psychosocial_care_plan_id)
    end
  end
end
