# POST /hl7/v2: uma mensagem ER7 no corpo (application/hl7-v2, até 1 MB, lido
# com teto). O tipo não é registrado: o Rails não o põe em params nem no log.
module Hl7
  class V2Controller < BaseController
    MEDIA_TYPE = "application/hl7-v2".freeze
    MAX_BODY = 1_048_576

    def create
      return render(json: { error: "unsupported_media_type" }, status: :unsupported_media_type) unless request.media_type == MEDIA_TYPE

      request.body.rewind
      body = request.body.read(MAX_BODY + 1).to_s
      return render(json: { error: "payload_too_large" }, status: :payload_too_large) if body.bytesize > MAX_BODY

      reply = Lab::Hl7::Inbound.call(raw: body, token: @token, city_slug: Current.city.slug, fake_allowed: fake_allowed?)
      render plain: reply, content_type: "#{MEDIA_TYPE}; charset=utf-8"
    end
  end
end
