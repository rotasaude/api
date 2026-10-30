# Odontograma e histórico de eventos do paciente (ADR 0046; contrato §16 O1,
# O13). Nominal: acesso do prontuário e uma trilha dental por leitura. O dente
# nunca vai na URL: a lista pagina por `before`/`limit` e a tela filtra.
module DentalCare
  class ChartsController < BaseController
    def show
      read_patient do |patient|
        plans = DentalTreatmentPlan.open_plans.where(patient_id: patient.id).includes(:health_unit).order(:created_at, :id).to_a
        render json: Json.odontogram(patient, Chart.call(patient), plans)
        true
      end
    end

    def events
      read_patient do |patient|
        limit = page_limit
        next false unless limit

        scope = DentalChartEvent.where(patient_id: patient.id)
        if params[:before].present?
          begin
            at, seq = EventCursor.decode(params[:before])
          rescue EventCursor::Invalid
            render_refusal("before", "invalid_cursor")
            next false
          end
          scope = scope.where("(dental_chart_events.recorded_at, dental_chart_events.seq) < (?, ?)", at, seq)
        end
        rows = scope.select("dental_chart_events.*", "dental_chart_events.seq AS event_seq")
                    .order(Arel.sql("dental_chart_events.recorded_at DESC, dental_chart_events.seq DESC"))
                    .includes(author_user: :professional).limit(limit + 1).to_a
        page = rows.first(limit)
        names = Json.procedure_names(page.filter_map(&:procedure_code))
        next_before = rows.size > limit ? EventCursor.encode(page.last.recorded_at, page.last[:event_seq]) : nil
        render json: { events: page.map { |e| Json.chart_event(e, names: names) }, next_before: next_before }
        true
      end
    end
  end
end
