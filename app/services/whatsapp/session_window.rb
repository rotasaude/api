# Janela de atendimento de 24h do WhatsApp (F-01.7). Fora dela, só template
# aprovado pode ser enviado. Determinada pelo último inbound do telefone, no
# banco da cidade da conexão corrente.
module Whatsapp
  module SessionWindow
    WINDOW = 24.hours

    def self.open?(phone:)
      last = InboundMessage.where(from: phone).maximum(:created_at)
      last.present? && last > WINDOW.ago
    end
  end
end
