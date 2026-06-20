# Envia mensagem fora-de-banda (ADR-0014/0021). Escopo manual sobre
# municipality_channels (RLS-exempt).
class SendWhatsappJob < ApplicationJob
  include TenantScopedJob

  def perform(to:, body:, municipality_id:)
    with_tenant(municipality_id) do
      channel = ApplicationRecord.connected_to(role: :admin) do
        MunicipalityChannel.find_by!(municipality_id: municipality_id, active: true)
      end
      Whatsapp::Outbound.new(channel).deliver_text(to: to, body: body)
    end
  end
end
