# Módulo 15 (ADR 0027): protocolos com offer/suggestions, pares com perfil e
# triagens concluídas no passado (para o intervalo de repetição).
module TriageCatalogHelpers
  # Data de nascimento de quem faz `age` anos exatamente em `on`.
  def birth_date_for(age, on: Time.zone.today) = (on - age.years).iso8601

  # Um passo boolean "q1" (sim = 4 pontos → tier media, prioridade 5, não
  # urgente). priority_when pode tornar o "sim" urgente.
  def catalog_definition(name, offer: nil, suggestions: nil, priority_when: nil)
    {
      "name" => name, "version" => 1, "start_step_id" => "q1",
      "steps" => [ { "id" => "q1", "prompt" => "Tudo bem?", "answer_type" => "boolean",
                     "branches" => { "true" => nil, "false" => nil }, "weights" => { "true" => 4, "false" => 0 } } ],
      "scoring" => { "type" => "weighted", "thresholds" => { "baixa" => 0, "media" => 3 },
                     "priority_map" => { "baixa" => 9, "media" => 5 } },
      "offer" => offer, "suggestions" => suggestions, "priority_when" => priority_when
    }.compact
  end

  def active_protocol!(name, version: 1, **opts)
    definition = catalog_definition(name, **opts).merge("version" => version)
    ProtocolDefinition.create!(name: name, version: version, status: "active", definition: definition)
  end

  def profiled_citizen!(age:, sex: "female", phone: "+5541998765432", cpf: nil, source: "declared", neighborhood: nil)
    Citizen.create!(cpf: cpf || CampaignHistory.cpf_for("#{phone}:#{age}:#{sex}"), phone: phone,
                    birth_date: birth_date_for(age), sex: sex, profile_source: source, neighborhood: neighborhood)
  end

  # Triagem web concluída em `at`, sem passar pelo fluxo (para datas no passado).
  def completed_triage!(citizen, protocol_name, at: Time.current)
    definition = ProtocolDefinition.find_by!(name: protocol_name, status: "active")
    conversation = Conversation.create!(channel: "web", citizen: citizen, phone: citizen.phone, state: "completed")
    Triage.create!(conversation: conversation, protocol_definition: definition, protocol_name: protocol_name,
                   status: "completed", tier: "baixa", priority: 9, answers: { "q1" => "false" },
                   created_at: at, completed_at: at)
  end

  # Início pelo comando da web, com o consentimento vigente.
  def start_for!(citizen, protocol_name)
    Citizens::StartConversation.call(citizen: citizen, consent_version: Consents.current_version,
                                     session_id: "spec", protocol_name: protocol_name)
  end
end

RSpec.configure { |c| c.include TriageCatalogHelpers }
