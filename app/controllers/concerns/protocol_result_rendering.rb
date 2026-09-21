# Um só lugar traduz o Result de um command de protocolo para HTTP (fatia 2
# das assinaturas). A mensagem é a do próprio command — texto nosso, com a
# contagem de assinaturas que faltam —, nunca a de uma exceção.
module ProtocolResultRendering
  STATUS_FOR = { forbidden: :forbidden, not_found: :not_found }.freeze

  private

  def render_protocol_result(result)
    if result.ok?
      protocol = result.payload[:protocol_definition]
      render json: { ok: true, protocol: { name: protocol.name, version: protocol.version, status: protocol.status } }
    else
      render json: { error: result.reason.to_s, message: result.message }.compact,
             status: STATUS_FOR.fetch(result.reason, :unprocessable_entity)
    end
  end
end
