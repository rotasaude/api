# GET /citizen/contact_preferences — por pessoa do telefone da sessão (o
#   cidadão não tem nome: cpf_masked), mais sms_available (a chave da cidade).
# PUT /citizen/contact_preferences/:citizen_id { sms_opt_in?, notices_muted? }
#   — pessoa de outro telefone: 404.
module CitizenApi
  class ContactPreferencesController < BaseController
    def index
      citizens = current_citizen_session.citizens.order(:created_at).to_a
      preferences = CitizenContactPreference.where(citizen_id: citizens.map(&:id)).index_by(&:citizen_id)
      render json: {
        sms_available: Campaigns::SmsSetting.enabled?,
        people: citizens.map { |c| person_json(c, preferences[c.id] || CitizenContactPreference.new(citizen_id: c.id)) }
      }
    end

    def update
      citizen = current_citizen_session.citizens.find_by(id: params[:citizen_id])
      return render_error("not_found", :not_found) unless citizen

      result = Citizens::UpdateContactPreferences.call(citizen: citizen, changes: request.request_parameters)
      return render_error(result.reason, :unprocessable_entity) if result.failure?

      render json: person_json(citizen, result.payload[:preference])
    end

    private

    def person_json(citizen, preference)
      { citizen_id: citizen.id, cpf_masked: citizen.cpf_masked, sms_opt_in: preference.sms_opt_in,
        notices_muted: preference.notices_muted }
    end
  end
end
