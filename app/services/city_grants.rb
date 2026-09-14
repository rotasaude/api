# Grant assinado de entrada numa cidade (spec banco-por-cidade §5, Plano 3B).
#
# Quem emite: o console (operador entrando numa cidade) e o callback do gov.br
# em auth.* (usuário voltando para a cidade dele). Quem consome: a cidade, em
# POST /session/grant, que cria a Session local.
#
# Garantias:
#   - validade de TTL (60 s) no token E na linha;
#   - uso único: o consumo é um UPDATE condicional que precisa afetar 1 linha, então
#     duas requisições com o mesmo token não abrem duas sessões;
#   - vale só na cidade emitida: o slug do token é comparado com a cidade do host
#     ANTES de consumir (um grant de A apresentado em B não é gasto);
#   - kind e sujeito saem da LINHA, nunca do token.
#
# A assinatura usa a chave da plataforma (message_verifier, derivada do
# secret_key_base). Chave por cidade é do Plano 6.
module CityGrants
  TTL = 60.seconds
  PURPOSE = :city_grant

  module_function

  def issue(city:, kind:, subject_id:)
    grant = CityGrant.create!(city: city, kind: kind, subject_id: subject_id, expires_at: TTL.from_now)
    verifier.generate({ "jti" => grant.id, "city" => city.slug }, purpose: PURPOSE, expires_in: TTL)
  end

  def redeem(token:, city:)
    return nil unless token.is_a?(String) && token.present?

    payload = verifier.verified(token, purpose: PURPOSE)
    return nil unless payload.is_a?(Hash) && payload["city"] == city.slug && payload["jti"].present?

    now = Time.current
    consumed = CityGrant.where(id: payload["jti"], city_id: city.id, consumed_at: nil)
                        .where("expires_at > ?", now)
                        .update_all(consumed_at: now, updated_at: now)
    return nil unless consumed == 1

    CityGrant.find(payload["jti"])
  end

  def verifier
    Rails.application.message_verifier(PURPOSE)
  end
end
