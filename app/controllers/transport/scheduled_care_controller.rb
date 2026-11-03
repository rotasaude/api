# POST /transport/scheduled_care { date, destination_id?, health_unit_id? }
# (contrato §4; §14 T5) → { items } (Transport::ScheduledCare). Só a central;
# tudo no corpo (query → 422). Sem trilha: o item não traz dado clínico.
module Transport
  class ScheduledCareController < BaseController
    before_action { forbid unless Access.dispatcher?(Current.user) }

    def create
      return unless query_only!

      date = Support.date(body_param("date"))
      return render_refusal("date") unless date

      ids = {}
      %w[destination_id health_unit_id].each do |key|
        value = body_param(key)
        next if value.nil?
        return render_refusal(key) unless uuid?(value)

        ids[key.to_sym] = value
      end
      render json: { items: ScheduledCare.call(date: date, **ids) }
    end
  end
end
