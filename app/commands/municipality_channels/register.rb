# Registra o canal WhatsApp de uma cidade (CityChannel, na PLATAFORMA). Era parte
# do antigo ProvisionMunicipality; no provisionamento em duas fases (Plano 4) o
# canal é um passo à parte, feito quando a Meta libera o número. Só cidade ativa.
# Auditoria sem o token nem o telefone (ADR-0012/0013).
module MunicipalityChannels
  module Register
    def self.call(city:, phone_number_id:, waba_id:, display_phone_number:, access_token:)
      unless city.servable?
        return Result.fail(:city_not_servable, message: "cidade #{city.slug} não está ativa (status=#{city.status})")
      end
      return Result.fail(:invalid, message: "access_token vazio") if access_token.blank?

      channel = nil
      PlatformRecord.transaction do
        channel = CityChannel.create!(city: city, phone_number_id: phone_number_id, waba_id: waba_id,
                                      display_phone_number: display_phone_number, access_token: access_token,
                                      active: true)
        Platform.audit("channel.registered", city_id: city.id, phone_number_id: channel.phone_number_id)
      end
      Result.ok(channel: channel)
    rescue ActiveRecord::RecordInvalid => e
      Result.fail(:invalid, message: e.record.errors.full_messages.join(", "))
    rescue ActiveRecord::RecordNotUnique
      Result.fail(:invalid, message: "phone_number_id já registrado")
    end
  end
end
