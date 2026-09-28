# Módulo 11 (ADR 0023): casos com bairro para os painéis e para o trigger.
module TerritoryHelpers
  # Triagem de um cidadão web NOVO (conversa própria), com o bairro copiado no
  # INSERT — como StartTriage faz. nil = cidadão sem bairro.
  def territory_triage!(neighborhood, status: "completed", priority: 1, tier: "alta", created_at: 2.hours.ago)
    protocol = ProtocolDefinition.find_by(name: StartTriage::DEFAULT_PROTOCOL_NAME, status: "active") ||
               create_default_protocol!
    phone = "+55419#{SecureRandom.random_number(10**8).to_s.rjust(8, '0')}"
    citizen = Citizen.create!(cpf: "52998224725", phone: phone, neighborhood: neighborhood)
    completed = status == "completed"
    conversation = Conversation.create!(channel: "web", citizen: citizen, phone: phone,
                                        state: completed ? "completed" : "consented", created_at: created_at)
    Triage.create!(conversation: conversation, protocol_definition: protocol, protocol_name: protocol.name,
                   status: status, tier: completed ? tier : nil, priority: completed ? priority : nil,
                   answers: {}, created_at: created_at, completed_at: completed ? created_at + 5.minutes : nil,
                   neighborhood_id: neighborhood&.id)
  end

  # Relatório só para os painéis (assinatura falsa: /r/:token não o acha).
  def territory_report!(triage)
    token = "tok-#{SecureRandom.hex(8)}"
    ReportSnapshot.create!(triage: triage, protocol_definition: triage.protocol_definition, token: token,
                           signature: "sig-#{token}", payload: { "tier" => triage.tier },
                           outcome: { "tier" => triage.tier }, expires_at: 10.days.from_now)
  end
end

RSpec.configure { |c| c.include TerritoryHelpers }
