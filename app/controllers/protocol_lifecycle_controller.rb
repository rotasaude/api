# Ciclo de vida do protocolo na cidade, com assinaturas (spec de
# assinaturas §4 e §8, ADR-0016). Endpoints finos: a regra mora nos commands.
#
# Step-up de MFA (ADR-0011) em todo ato que aprova ou põe em uso — assinar,
# ativar, aposentar, reverter; a publicação mora em PublicationsController.
# Enviar para revisão não aprova nada e não pede step-up.
#
# Sessão de operador (grant) é só leitura: nenhuma ação aqui entra em
# allow_operator_grant_access.
class ProtocolLifecycleController < ApplicationController
  include Authentication
  include MfaStepUp
  include ProtocolResultRendering

  before_action :require_step_up!, except: :submit

  def submit
    render_protocol_result(Protocols::SubmitForReview.call(name: protocol_name, version: version, by: Current.user))
  end

  def sign
    result = Protocols::Sign.call(name: protocol_name, version: version, purpose: params.require(:purpose),
                                  by: Current.user)
    return render_protocol_result(result) unless result.ok?

    signature = result.payload[:signature]
    render json: { ok: true,
                   protocol: { name: signature.protocol_definition.name, version: signature.protocol_definition.version,
                               status: signature.protocol_definition.status },
                   signature: { purpose: signature.purpose, created_at: signature.created_at.iso8601 } }
  end

  def activate
    render_protocol_result(Protocols::Activate.call(version: version, name: protocol_name, by: Current.user))
  end

  def retire
    render_protocol_result(Protocols::Retire.call(version: version, name: protocol_name, by: Current.user))
  end

  def revert
    render_protocol_result(Protocols::RevertActivation.call(name: protocol_name, reason: params[:reason].to_s,
                                                            by: Current.user))
  end

  private

  def protocol_name = params.require(:name)
  def version = Integer(params.require(:version))
end
