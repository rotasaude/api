# Dataset de demonstração dos painéis do dashboard (opt-in): popula cada visão
# (Aquisição/Triagem/Governança) de cada cidade de dev, de forma idempotente,
# espalhado pelos últimos 30 dias.
#
# Por cidade: tudo roda dentro da conexão da cidade (CityConnection.with) — não há
# coluna de município nem conexão privilegiada. Chaves naturais determinísticas
# (message_id, idempotency_key, payload.demo_id, token) tornam a re-execução um
# no-op.
#
# Rodar:     bin/rails db:seed:demo          (pré-requisito: bin/rails city:dev_baseline)
# Verificar: bin/rails db:seed:demo:verify
module DashboardDemo
  module_function

  CITIES = [
    { slug: "curitiba", scale: 1.0, code: "CWB", ddd: "41" },
    { slug: "maringa",  scale: 0.4, code: "MGA", ddd: "44" }
  ].freeze

  # Distribuição de estados da FSM (base Curitiba; escalada por cidade). Cobre
  # todo bucket do funil (greeting/awaiting_consent/consented), o live
  # (awaiting_consent + consented) e as saídas (revoked). "completed" é terminal e
  # fica fora do funil por desenho.
  STATE_DIST = { "greeting" => 4, "awaiting_consent" => 4, "consented" => 12,
                 "completed" => 8, "revoked" => 3, "abandoned" => 3 }.freeze

  # Status de outbound é inteiro literal 0–5: {0,1,2}=ok, {3}=warn, {4,5}=err
  # (ingestion_query).
  ACK_STATUS_CYCLE = [ 0, 1, 2, 0, 1, 2, 3, 4, 5, 2, 0, 3, 4 ].freeze

  TIER_CYCLE = %w[low medium high medium low high medium high].freeze
  # Prioridade na faixa do contrato (1..9, menor = mais urgente).
  SEED_PRIORITY = { "high" => 1, "medium" => 5, "low" => 9 }.freeze
  MODE_CYCLE = %w[weighted weighted decision_table].freeze
  # Conversas consentidas só têm triagem completed ou in_progress; os in_progress
  # mantêm a taxa de conclusão abaixo de 100%.
  TRIAGE_STATUS_CYCLE = %w[completed completed completed completed in_progress completed in_progress completed].freeze

  # Timestamp determinístico `days` atrás, em hora/minuto fixos.
  def at_days_ago(days, hour: 10)
    (Time.current - days.to_i.days).change(hour: hour, min: (days.to_i * 7) % 60, sec: 0)
  end

  # Índice i em [0, n) → deslocamento em dias em [0, 29].
  def spread_days(i, n)
    n <= 1 ? 0 : ((i * 29.0) / (n - 1)).round
  end

  def scaled(base, cfg)
    [ (base * cfg[:scale]).round, 1 ].max
  end

  def actor(cfg, who)
    "#{who}@#{cfg[:slug]}.demo"
  end

  # Definição válida (passa Protocols::Validator), mesmo formato do seed base.
  def demo_definition(name, version)
    {
      "name" => name, "version" => version, "start_step_id" => "tosse",
      "steps" => [
        { "id" => "tosse", "prompt" => "Você está com tosse?", "answer_type" => "boolean",
          "branches" => { "true" => "febre", "false" => nil }, "weights" => { "true" => 3, "false" => 0 } },
        { "id" => "febre", "prompt" => "Está com febre alta?", "answer_type" => "boolean",
          "branches" => { "true" => nil, "false" => nil }, "weights" => { "true" => 5, "false" => 0 } }
      ],
      "scoring" => { "type" => "weighted", "thresholds" => { "baixa" => 0, "alta" => 5 },
                     "priority_map" => { "baixa" => 9, "alta" => 1 } },
      "recommendations" => {
        "alta"  => { "title" => "Procure atendimento hoje", "body" => "Prioridade alta. Procure a unidade mais próxima." },
        "baixa" => { "title" => "Cuidados em casa", "body" => "Repouso e hidratação; se piorar, procure sua unidade." }
      }
    }
  end

  def upsert_protocol(name, version, status)
    ProtocolDefinition.find_or_create_by!(name: name, version: version) do |p|
      p.status = status
      p.definition = demo_definition(name, version)
    end
  end

  # Várias versões/status para o painel Protocolos. v1 ativa reaproveita a linha
  # do seed base, se existir.
  def build_protocols
    resp1 = upsert_protocol("triage-respiratoria", 1, "active")
    upsert_protocol("triage-respiratoria", 2, "published")
    upsert_protocol("triage-respiratoria", 3, "draft")
    dengue1 = upsert_protocol("triagem-dengue", 1, "active")
    upsert_protocol("triagem-dengue", 2, "retired")
    [ resp1, dengue1 ].each { |protocol| ensure_baseline_activation(protocol) }
    { "triage-respiratoria" => resp1, "triagem-dengue" => dengue1 }
  end

  # Linha-base (fatia 2 das assinaturas), como no db/seeds.rb: a versão nasce
  # ativa no dado de demonstração, como uma versão que já estava em uso antes das
  # assinaturas — sem ela, a reversão de emergência não tem para onde voltar.
  # Idempotente: protocol_activations só aceita acréscimo, então só cria quando
  # a versão ainda não tem linha nenhuma.
  def ensure_baseline_activation(protocol)
    return if protocol.activations.exists?

    protocol.activations.create!(kind: "baseline", actor_kind: "system", actor_id: nil,
                                 created_at: protocol.activated_at || protocol.created_at)
  end

  def build_conversations_and_consents(cfg)
    triage_convos = []
    seq = 0
    STATE_DIST.each do |state, base|
      scaled(base, cfg).times do
        seq += 1
        phone = format("+55%s9%08d", cfg[:ddd], seq)
        # Espalhamento coprimo sobre [0,29]: intercala estados pela janela de 30d.
        days  = (seq * 13) % 30
        convo = Conversation.find_or_create_by!(phone: phone) do |c|
          c.state = state
          c.created_at = at_days_ago(days, hour: 9)
        end

        if %w[consented completed revoked].include?(state)
          version = seq.even? ? 2 : 1
          Consent.where(conversation_id: convo.id).first || Consent.create!(
            conversation: convo, version: version,
            channel: "whatsapp", policy_text_sha: "demo-policy-sha-v#{version}",
            given_at: at_days_ago(days, hour: 11),
            revoked_at: (state == "revoked" ? at_days_ago([ days - 1, 0 ].max, hour: 12) : nil)
          )
        end

        triage_convos << { convo: convo, state: state, days: days, seq: seq } if %w[consented completed].include?(state)
      end
    end
    triage_convos
  end

  # Inbound em 30d (dia 0 → <24h pendente; dias ≥ 2 → backlog >24h) e log de ack.
  def build_ingestion(cfg)
    n_in = scaled(40, cfg)
    n_in.times do |i|
      InboundMessage.find_or_create_by!(message_id: "IN-#{cfg[:code]}-#{format('%04d', i + 1)}") do |m|
        m.from = format("+55%s9%08d", cfg[:ddd], i + 1)
        m.kind = "text"
        m.raw = "demo inbound message #{i + 1}"
        m.created_at = at_days_ago(spread_days(i, n_in), hour: (i % 12) + 8)
      end
    end

    n_out = scaled(30, cfg)
    n_out.times do |i|
      OutboundMessage.find_or_create_by!(idempotency_key: "OUT-#{cfg[:code]}-#{format('%04d', i + 1)}") do |m|
        m.to = format("+55%s9%08d", cfg[:ddd], i + 1)
        m.status = ACK_STATUS_CYCLE[i % ACK_STATUS_CYCLE.length]
        m.template = { "name" => "rota_saude_ask", "language" => { "code" => "pt_BR" } }
        m.created_at = at_days_ago(spread_days(i, n_out), hour: (i % 12) + 8)
      end
    end
  end

  def build_triages_and_reports(cfg, citizens, protocols)
    protos = protocols.values
    built = []
    citizens.each_with_index do |c, i|
      convo = c[:convo]
      days  = c[:days]
      proto = protos[i % protos.size]
      status = c[:state] == "completed" ? "completed" : TRIAGE_STATUS_CYCLE[i % TRIAGE_STATUS_CYCLE.size]
      completed = status == "completed"
      tier = TIER_CYCLE[i % TIER_CYCLE.size]
      mode = MODE_CYCLE[i % MODE_CYCLE.size]
      priority = SEED_PRIORITY.fetch(tier)
      started_at = at_days_ago(days, hour: 9)
      completed_at = completed ? started_at + (3 + (i % 8)).minutes : nil

      triage = Triage.where(conversation_id: convo.id, protocol_definition_id: proto.id).first
      triage ||= Triage.create!(
        conversation: convo, protocol_definition: proto, protocol_name: proto.name,
        status: status,
        tier: (completed ? tier : nil), priority: (completed ? priority : nil),
        current_step: "febre",
        answers: { "tosse" => "true", "febre" => (tier == "high" ? "true" : "false") },
        created_at: started_at, completed_at: completed_at,
        outcome: (completed ? {
          "status" => "terminal", "tier" => tier, "priority" => priority,
          "scoring" => { "mode" => mode, "score" => (tier == "high" ? 8 : tier == "medium" ? 4 : 1) },
          "trail" => [ { "step" => "tosse", "answer" => "true" },
                       { "step" => "febre", "answer" => (tier == "high" ? "true" : "false") } ]
        } : {})
      )

      built << { triage: triage, tier: tier, mode: mode, priority: priority, days: days, completed: completed }

      next unless completed

      expired = (i % 4).zero?
      upsert_report(cfg, triage, tier,
                    created_at: completed_at,
                    expires_at: (expired ? at_days_ago(days + 2, hour: 9) : Time.current + 20.days))
    end
    built
  end

  # Snapshot montado direto (não via GenerateReportJob) para retroagir created_at e
  # expires_at e ter mistura de relatórios vivos e expirados.
  def upsert_report(cfg, triage, tier, created_at:, expires_at:)
    return if ReportSnapshot.where(triage_id: triage.id).exists?

    token = "RPT-#{cfg[:code]}-#{triage.id.to_s[0, 8]}"
    ReportSnapshot.create!(
      triage: triage, protocol_definition: triage.protocol_definition,
      outcome: { "tier" => tier, "priority" => triage.priority, "status" => "terminal" },
      payload: { "tier" => tier, "priority" => triage.priority, "completed_at" => triage.completed_at&.iso8601 },
      token: token, signature: ReportSnapshot.sign(token),
      created_at: created_at, expires_at: expires_at
    )
  end

  # Idempotente por payload.demo_id sintético (domain_events não tem chave natural).
  def upsert_event(demo_id, name:, occurred_at:, payload:)
    existing = DomainEvent.where("payload ->> 'demo_id' = ?", demo_id).first
    return existing if existing

    DomainEvent.create!(
      name: name, occurred_at: occurred_at, published_at: occurred_at, created_at: occurred_at,
      payload: payload.merge("demo_id" => demo_id)
    )
  end

  def build_events(cfg, protocols, citizens, triages)
    code = cfg[:code]
    ana = actor(cfg, "ana")
    bruno = actor(cfg, "bruno")

    # Eventos de auditoria de protocolo (four-eyes + protocol_events).
    respv2 = ProtocolDefinition.find_by!(name: "triage-respiratoria", version: 2)
    dengue1 = protocols["triagem-dengue"]
    dengue2 = ProtocolDefinition.find_by!(name: "triagem-dengue", version: 2)

    # respiratoria v2: criada por A, publicada por B → fourEyes = true
    upsert_event("#{code}-P-RESP2-C", name: "protocol.created", occurred_at: at_days_ago(20),
                 payload: { "protocol_definition_id" => respv2.id, "name" => "triage-respiratoria", "version" => 2, "actor" => ana })
    upsert_event("#{code}-P-RESP2-P", name: "protocol.published", occurred_at: at_days_ago(18),
                 payload: { "protocol_definition_id" => respv2.id, "name" => "triage-respiratoria", "version" => 2, "actor" => bruno })
    # dengue v1: criada e publicada pelo MESMO ator → fourEyes = false
    upsert_event("#{code}-P-DENG1-C", name: "protocol.created", occurred_at: at_days_ago(25),
                 payload: { "protocol_definition_id" => dengue1.id, "name" => "triagem-dengue", "version" => 1, "actor" => ana })
    upsert_event("#{code}-P-DENG1-P", name: "protocol.published", occurred_at: at_days_ago(24),
                 payload: { "protocol_definition_id" => dengue1.id, "name" => "triagem-dengue", "version" => 1, "actor" => ana })
    # dengue v2 aposentada
    upsert_event("#{code}-P-DENG2-R", name: "protocol.retired", occurred_at: at_days_ago(10),
                 payload: { "protocol_definition_id" => dengue2.id, "name" => "triagem-dengue", "version" => 2, "actor" => bruno })

    # conversation.* e consent.* (prefixos do filtro de Eventos)
    citizens.each_with_index do |c, i|
      convo = c[:convo]
      days = c[:days]
      upsert_event("#{code}-CV-#{i}", name: "conversation.consented", occurred_at: at_days_ago(days, hour: 10),
                   payload: { "conversation_id" => convo.id, "actor" => "sistema" })
      upsert_event("#{code}-CO-#{i}", name: "consent.given", occurred_at: at_days_ago(days, hour: 11),
                   payload: { "conversation_id" => convo.id, "actor" => "cidadão" })
    end

    # Eventos de trilha (nomes crus, por triagem completa) + triage./priority.
    triages.each_with_index do |t, i|
      next unless t[:completed]

      tri = t[:triage]
      base = at_days_ago(t[:days], hour: 9)
      upsert_event("#{code}-T-SC-#{i}", name: "scored", occurred_at: base + 1.minute,
                   payload: { "triage_id" => tri.id, "rule" => "weighted", "ref" => "mode:#{t[:mode]}", "out" => t[:tier], "actor" => "sistema" })
      upsert_event("#{code}-T-TA-#{i}", name: "tier_assigned", occurred_at: base + 2.minutes,
                   payload: { "triage_id" => tri.id, "rule" => "threshold", "ref" => "tier", "out" => t[:tier], "actor" => "sistema" })
      upsert_event("#{code}-T-DONE-#{i}", name: "triage.completed", occurred_at: base + 3.minutes,
                   payload: { "triage_id" => tri.id, "actor" => "sistema" })
      next unless t[:priority] == 1

      upsert_event("#{code}-T-PR-#{i}", name: "priority_rule", occurred_at: base + 2.minutes,
                   payload: { "triage_id" => tri.id, "rule" => "escalate", "ref" => "priority", "out" => "1", "actor" => "sistema" })
      upsert_event("#{code}-PRI-#{i}", name: "priority.escalated", occurred_at: base + 3.minutes,
                   payload: { "triage_id" => tri.id, "actor" => "sistema" })
    end
  end

  # Semeia a cidade da conexão CORRENTE. Quem chama escolhe a cidade.
  def seed_current_city(cfg)
    protocols = build_protocols
    citizens = build_conversations_and_consents(cfg)
    build_ingestion(cfg)
    triages = build_triages_and_reports(cfg, citizens, protocols)
    build_events(cfg, protocols, citizens, triages)

    {
      conversations: Conversation.count, consents: Consent.count, inbound: InboundMessage.count,
      outbound: OutboundMessage.count, triages: Triage.count, reports: ReportSnapshot.count,
      protocols: ProtocolDefinition.count, events: DomainEvent.count
    }
  end

  def run!
    CITIES.filter_map do |cfg|
      city = City.find_by(slug: cfg[:slug])
      unless city&.servable?
        warn "[dashboard_demo] #{cfg[:slug]} ausente ou inativa no catálogo — pulada (rode bin/rails city:dev_baseline)"
        next
      end

      counts = nil
      Current.set(city: city) { CityConnection.with(city) { counts = seed_current_city(cfg) } }
      puts "[dashboard_demo] #{cfg[:slug]} #{counts.inspect}"
      counts
    end
  end

  # Falhas da cidade da conexão CORRENTE (vazio = todos os painéis populados).
  def verify_current_city(slug)
    tz = ActiveSupport::TimeZone["America/Sao_Paulo"]
    p = Admin::Api::Period.parse(key: "30d", from: nil, to: nil, tz: tz)
    failures = []
    check = ->(cond, msg) { failures << "#{slug}: #{msg}" unless cond }

    cv = Admin::ConversationsQuery.call(period: p)
    check.call(cv[:funnel].sum { |f| f[:count] }.positive?, "conversations funnel empty")
    check.call(cv[:live].to_i.positive?, "no live conversations")

    co = Admin::ConsentQuery.call(period: p)
    check.call(co[:given].to_i.positive?, "no consents given")
    check.call(co[:revoked].to_i.positive?, "no consents revoked")

    ig = Admin::IngestionQuery.call(period: p)
    check.call(ig[:inboundTotal].to_i.positive?, "no inbound messages")
    check.call(ig[:ack].sum { |a| a[:count] }.positive?, "ack breakdown empty")

    tr = Admin::TriagesQuery.call(period: p)
    check.call(tr[:started].to_i.positive?, "no triages started")

    cl = Admin::ClassificationQuery.call(period: p)
    check.call(cl[:tiers].all? { |t| t[:count].to_i.positive? }, "a tier bucket is empty")
    check.call(cl[:priorityTrue].to_i.positive?, "no priority triages")
    check.call(cl[:byMode].size >= 2, "<2 scoring modes")

    rp = Admin::ReportsQuery.call(period: p)
    check.call(rp[:reports].any? { |r| r[:live] }, "no live reports")
    check.call(rp[:reports].any? { |r| !r[:live] }, "no expired reports")

    pr = Admin::ProtocolsQuery.index
    check.call(pr[:list].size >= 5, "<5 protocol rows")

    ev = Admin::EventsQuery.call(name: nil, from: nil, to: nil, period: p)
    names = ev[:byType].map { |x| x[:name] }
    %w[triage. consent. conversation. protocol. priority.].each do |pre|
      check.call(names.any? { |n| n.start_with?(pre) }, "no events for prefix #{pre}")
    end

    failures
  end

  def verify!
    CITIES.flat_map do |cfg|
      city = City.find_by(slug: cfg[:slug])
      next [ "#{cfg[:slug]}: city missing or not active in the catalog" ] unless city&.servable?

      CityConnection.with(city) { verify_current_city(cfg[:slug]) }
    end
  end
end
