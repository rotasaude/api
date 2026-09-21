# Publicação de protocolo exige step-up de MFA (ADR-0011 + ADR-0009).
class PublicationsController < ApplicationController
  include Authentication
  include MfaStepUp
  include ProtocolResultRendering

  def create
    return require_step_up! unless reauthenticated_recently?(via: :totp)

    result = Protocols::Publish.call(version: params[:version], name: params[:name], by: Current.user)
    return render_protocol_result(result) unless result.ok?

    # `id` é o formato que o dashboard consome hoje (Plano 1) — mantido ao
    # lado de `protocol`, o formato novo e único, para não quebrar o
    # dashboard nesta task (ver relatório da Task 3).
    protocol = result.payload[:protocol_definition]
    render json: { ok: true, id: protocol.id,
                   protocol: { name: protocol.name, version: protocol.version, status: protocol.status } }
  end
end
