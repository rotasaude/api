# POST /hl7/v2: uma mensagem ER7 no corpo (application/hl7-v2, até 1 MB, lido
# com teto). O middleware Hl7RawBody guarda o corpo bruto e troca o tipo para
# text/plain antes de qualquer leitura de parâmetros: o Rails nunca o põe em
# params nem no log, qualquer que seja o Content-Type enviado.
module Hl7
  class V2Controller < BaseController
    MEDIA_TYPE = "application/hl7-v2".freeze
    MAX_BODY = 1_048_576

    def create
      content_type = request.env[Hl7RawBody::TYPE_KEY].to_s.split(";").first.to_s.strip.downcase
      return render(json: { error: "unsupported_media_type" }, status: :unsupported_media_type) unless content_type == MEDIA_TYPE

      body = request.env[Hl7RawBody::BODY_KEY].to_s
      return render(json: { error: "payload_too_large" }, status: :payload_too_large) if body.bytesize > MAX_BODY

      reply = Lab::Hl7::Inbound.call(raw: body, token: @token, city_slug: Current.city.slug, fake_allowed: fake_allowed?)
      render plain: reply, content_type: "#{MEDIA_TYPE}; charset=utf-8"
    end
  end
end
