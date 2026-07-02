# Rotaciona o access_token do canal WhatsApp de um município (F-01.9).
# Custody: platform_operator (qualquer cidade) ou municipal_admin da cidade.
# Zero-downtime: Outbound lê o token fresco a cada envio. Auditoria via
# Platform.audit — SEM o valor do token (ADR-0011/0023).
module MunicipalityChannels
  module RotateToken
    def self.call(municipality_id:, new_token:, by:)
      return Result.fail(:invalid, message: "new_token vazio") if new_token.blank?

      ApplicationRecord.connected_to(role: :admin) do
        return Result.fail(:forbidden) unless authorized?(by, municipality_id)

        channel = MunicipalityChannel.active.find_by(municipality_id: municipality_id)
        return Result.fail(:not_found) unless channel

        channel.update!(access_token: new_token)
        Platform.audit(
          "channel.token_rotated",
          municipality_id: municipality_id,
          phone_number_id: channel.phone_number_id,
          by: by&.id
        )
        Result.ok(channel: channel)
      end
    end

    def self.authorized?(user, municipality_id)
      return false unless user
      user.memberships.active.any? do |m|
        m.role == "platform_operator" ||
          (m.role == "municipal_admin" && m.municipality_id == municipality_id)
      end
    end
    private_class_method :authorized?
  end
end
