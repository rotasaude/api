# Página para a tela de "sistemas externos" do e-SUS PEC (ADR 0035; spec §7;
# contrato §5). Host da cidade (CityResolution), sem sessão do Rota Saúde. A
# URL conferida é a que chegou (base_url + original_fullpath): atrás do proxy,
# Host e X-Forwarded-Proto precisam ser repassados (gate de go-live). Toda
# resposta: CSP com frame-ancestors do PEC da cidade ('none' sem
# configuração), sem X-Frame-Options, no-store e no-referrer (a URL tem CPF).
class PecTimelinesController < ApplicationController
  PAGE_LIMIT = 50
  # Defesa em profundidade: só uma origem simples entra na CSP.
  ORIGIN_FORMAT = %r{\Ahttps?://[a-z0-9.-]+(:\d+)?\z}

  before_action { @nonce = SecureRandom.base64(16) }

  def show
    url = "#{request.base_url}#{request.original_fullpath}"
    result = PecExternal::Authorize.call(city: Current.city, url: url, params: request.query_parameters)
    return failure(result.reason.to_s) if result.failure?

    grant = result.payload[:grant]
    page = Timeline::Query.call(person: grant.person, limit: self.class::PAGE_LIMIT)
    Timeline::Trail.viewed!(person: grant.person, access: "pec_external", user: grant.user)
    token = PecExternal::ViewSession.issue(city: Current.city, grant: grant)
    html(PecExternal::Page.timeline(display_name: grant.person.display_name, page: page, token: token, nonce: @nonce))
  end

  def more
    grant = PecExternal::ViewSession.resume(request.headers[PecExternal::ViewSession::HEADER], city: Current.city)
    return failure("pec_session_expired", status: :unauthorized) unless grant

    page = Timeline::Query.call(person: grant.person, before: Timeline::Cursor.decode(params[:before]), limit: self.class::PAGE_LIMIT)
    Timeline::Trail.viewed!(person: grant.person, access: "pec_external", user: grant.user)
    response.headers["X-Next-Before"] = page.next_before.to_s
    html(PecExternal::Page.items(page.entries))
  rescue Timeline::Cursor::Invalid
    failure("invalid_cursor", status: :unprocessable_entity)
  end

  private

  def failure(code, status: :forbidden) = html(PecExternal::Page.failure(code, nonce: @nonce), status: status)

  def html(body, status: :ok)
    origin = PecSetting.current&.pec_origin
    origin = nil unless origin.to_s.match?(ORIGIN_FORMAT)
    response.headers.delete("X-Frame-Options")
    response.headers["Content-Security-Policy"] =
      "default-src 'none'; style-src 'nonce-#{@nonce}'; script-src 'nonce-#{@nonce}'; connect-src 'self'; " \
      "base-uri 'none'; form-action 'none'; frame-ancestors #{origin.presence || "'none'"}"
    response.headers["Cache-Control"] = "no-store"
    response.headers["Referrer-Policy"] = "no-referrer"
    render body: body, content_type: "text/html; charset=utf-8", status: status
  end
end
