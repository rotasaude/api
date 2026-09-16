# POST /cities/:city_id/channel (Plano 8) — registra o canal WhatsApp de uma
# cidade ativa. O access_token é segredo: entra cifrado (CityChannel#encrypts,
# chave de PLATAFORMA) e NUNCA volta na resposta nem vai para log.
module Operators
  class CityChannelsController < BaseController
    def create
      city = City.find_by(id: params[:city_id].to_s)
      return head(:not_found) unless city

      result = MunicipalityChannels::Register.call(
        city: city,
        phone_number_id: params[:phone_number_id],
        waba_id: params[:waba_id],
        display_phone_number: params[:display_phone_number],
        access_token: params[:access_token]
      )

      if result.ok?
        channel = result.payload[:channel]
        render json: { id: channel.id, phone_number_id: channel.phone_number_id,
                       display_phone_number: channel.display_phone_number, active: channel.active },
               status: :created
      else
        render json: { error: result.reason.to_s, message: result.message }, status: :unprocessable_content
      end
    end
  end
end
