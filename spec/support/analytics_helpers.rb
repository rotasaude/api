# spec/support/analytics_helpers.rb
require Rails.root.join("lib/analytics_history").to_s

# Módulo 14 (ADR 0025): cenários para os consolidadores, o job e as leituras.
# O cru é gravado no passado pelo AnalyticsHistory (os comandos só aceitam
# "agora"); fatos e runs prontos servem às specs de leitura.
module AnalyticsHelpers
  # Protocolo de teste com as quatro formas de pergunta: boolean e enum
  # marcadas, boolean sensível SEM marca e integer marcado — inválido pelo
  # schema, mas gravável direto no banco: o consolidador precisa ignorar
  # mesmo assim.
  def analytics_definition(name: "triagem-arbovirose", version: 1, marks: %w[febre sintoma idade])
    steps = [
      { "id" => "febre", "prompt" => "Teve febre?", "answer_type" => "boolean",
        "branches" => { "true" => "sintoma", "false" => "sintoma" }, "weights" => { "true" => 3, "false" => 0 } },
      { "id" => "sintoma", "prompt" => "Qual o sintoma mais forte?", "answer_type" => "enum",
        "options" => [ "Manchas", "Dor nas juntas", "Nenhum" ],
        "branches" => { "Manchas" => "gestante", "Dor nas juntas" => "gestante", "Nenhum" => "gestante" },
        "weights" => { "Manchas" => 3, "Dor nas juntas" => 2, "Nenhum" => 0 } },
      { "id" => "gestante", "prompt" => "Está gestante?", "answer_type" => "boolean",
        "branches" => { "true" => "idade", "false" => "idade" }, "weights" => { "true" => 2, "false" => 0 } },
      { "id" => "idade", "prompt" => "Qual a sua idade?", "answer_type" => "integer", "branches" => {} }
    ]
    {
      "name" => name, "version" => version, "start_step_id" => "febre",
      "steps" => steps.map { |step| marks.include?(step["id"]) ? step.merge("analytic" => true) : step },
      "scoring" => { "type" => "weighted", "thresholds" => { "baixa" => 0, "alta" => 5 },
                     "priority_map" => { "baixa" => 9, "alta" => 1 } }
    }
  end

  def analytics_protocol!(version: 1, status: "active", marks: %w[febre sintoma idade], name: "triagem-arbovirose")
    ProtocolDefinition.create!(name: name, version: version, status: status,
                               definition: analytics_definition(name: name, version: version, marks: marks))
  end

  # Instante local (fuso da cidade) de um dia.
  def local_at(day, hour = 10, minute = 0)
    Time.zone.local(day.year, day.month, day.day, hour, minute)
  end

  def analytics_citizen!(neighborhood = nil)
    @analytics_citizen_seq = (@analytics_citizen_seq || 0) + 1
    AnalyticsHistory.citizen!(cpf: CampaignHistory.cpf_for("analytics-spec:#{@analytics_citizen_seq}:#{SecureRandom.hex(3)}"),
                              phone: format("+554195555%04d", @analytics_citizen_seq), neighborhood: neighborhood)
  end

  # Triagem de um cidadão novo, iniciada em `day` às `hour`:`minute` (hora local).
  def a_triage!(day:, hour: 10, minute: 0, neighborhood: nil, protocol: nil, **opts)
    protocol ||= ProtocolDefinition.find_by(name: StartTriage::DEFAULT_PROTOCOL_NAME, status: "active") ||
                 create_default_protocol!
    AnalyticsHistory.triage!(citizen: analytics_citizen!(neighborhood), protocol: protocol,
                             created_at: local_at(day, hour, minute), **opts)
  end

  def analytics_staff
    @analytics_staff ||= staff_with("recepcao-#{SecureRandom.hex(3)}@cidade.gov.br", "citizen_verifier")
  end

  # Atendimento da própria triagem; por padrão chega 30 min depois da conclusão.
  def an_attendance!(triage:, unit:, checked_in_at: nil, **opts)
    AnalyticsHistory.attendance!(citizen: triage.conversation.citizen, triage: triage, unit: unit, by: analytics_staff,
                                 checked_in_at: checked_in_at || triage.completed_at + 30.minutes, **opts)
  end

  def fact!(metric:, day:, value:, **attrs)
    AnalyticsDailyFact.create!({ metric: metric, day: day, value: value, dim: "", consolidated_at: Time.current }.merge(attrs))
  end

  def consolidated_run!(finished_at: 1.hour.ago)
    AnalyticsRun.create!(kind: "scheduled", status: "succeeded", window_from: Time.zone.today - 30,
                         window_to: Time.zone.today - 1, started_at: finished_at - 1.minute,
                         finished_at: finished_at, published_at: finished_at)
  end

  def scheduled_run!
    from, to = Analytics::Run.scheduled_window
    Analytics::Run.call(kind: "scheduled", from: from, to: to)
  end
end

RSpec.configure { |c| c.include AnalyticsHelpers }
