# Rotaciona o access_token do canal WhatsApp de uma cidade (F-01.9).
# O canal (CityChannel) mora na PLATAFORMA; o papel de quem rotaciona é lido no
# banco DA cidade. Custódia: municipal_admin da cidade. O operador de plataforma
# volta pelo Plano 3 (Operator + grant de entrada na cidade) — até lá não há
# operador entre os usuários de uma cidade.
# Zero-downtime: Outbound lê o token fresco a cada envio. Auditoria via
# Platform.audit com city_id — SEM o valor do token (ADR-0012/0013).
module MunicipalityChannels
  module RotateToken
    def self.call(city:, new_token:, by:)
      return Result.fail(:invalid, message: "new_token vazio") if new_token.blank?
      return Result.fail(:forbidden) unless authorized?(by, city)

      channel = CityChannel.active.find_by(city: city)
      return Result.fail(:not_found) unless channel

      channel.update!(access_token: new_token)
      Platform.audit(
        "channel.token_rotated",
        city_id: city.id,
        phone_number_id: channel.phone_number_id,
        by: by.id
      )
      Result.ok(channel: channel)
    end

    # `user` é um User do banco da cidade: o papel é checado na conexão DELA.
    def self.authorized?(user, city)
      return false unless user
      CityConnection.with(city) { user.has_role?("municipal_admin") }
    end
    private_class_method :authorized?
  end
end
