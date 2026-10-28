# Negativa semanal por unidade notificadora (contrato K7; papel `surveillance`):
#   GET  /surveillance/weekly_negatives?week=AAAA-SS  situação de cada unidade (padrão: a semana anterior)
#   POST /surveillance/weekly_negatives { unit_id, week }
# Só ids, nomes de unidade e semana: sem dado de pessoa, sem trilha.
module Surveillance
  class WeeklyNegativesController < BaseController
    before_action { forbid unless surveillance? }

    def index
      return unless query_only!(:week)

      week = params.key?(:week) ? EpiWeek.parse(params[:week]) : EpiWeek.current(Time.zone.today).pred
      return render_error("invalid_week") if week.nil?

      with_cases = WeekCases.unit_ids_with_cases(week)
      negatives = WeeklyNegativeReport.where(week: week.to_s).pluck(:health_unit_id).to_set
      units = HealthUnit.where(active: true, notifying: true).order(:name).map do |unit|
        { unit: unit_json(unit), status: status_of(unit, with_cases, negatives) }
      end
      render json: { week: week.to_s, units: units }
    end

    def create
      unit_id = body_param("unit_id")
      result = RecordNegative.call(unit_id: uuid?(unit_id) ? unit_id : nil, week: body_param("week"), by: Current.user)
      return render_failure(result) if result.failure?

      render json: { week: result.payload.fetch(:week).to_s, unit: unit_json(result.payload.fetch(:unit)), status: "negative" },
             status: :created
    end

    private

    # with_cases vence negative: com caso na semana a negativa não vale.
    def status_of(unit, with_cases, negatives)
      return "with_cases" if with_cases.include?(unit.id)

      negatives.include?(unit.id) ? "negative" : "pending"
    end

    def unit_json(unit) = { id: unit.id, cnes: unit.cnes, name: unit.name }
  end
end
