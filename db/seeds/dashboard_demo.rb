# Opt-in demo seed: populates every dashboard view (Aquisição/Triagem/Governança)
# for two municipalities, idempotently, spread over the last 30 days.
# Run: bin/rails db:seed:demo   (verify: bin/rails db:seed:demo:verify)
#
# All writes run under the admin (BYPASSRLS) connection because conversations,
# triages, consents, inbound/outbound messages, protocol_definitions,
# report_snapshots and domain_events are RLS-enforced and the seed runs without
# SET LOCAL. Idempotent via deterministic natural keys.
module DashboardDemo
  module_function

  CITIES = [
    { slug: "curitiba", name: "Curitiba Demo", uf: "PR", scale: 1.0, code: "CWB", ddd: "41" },
    { slug: "londrina", name: "Londrina Demo", uf: "PR", scale: 0.4, code: "LDB", ddd: "43" }
  ].freeze

  ACTOR_A = "ana@curitiba.demo".freeze
  ACTOR_B = "bruno@curitiba.demo".freeze

  # Deterministic timestamp `days` ago at a fixed hour/minute (no randomness).
  def at_days_ago(days, hour: 10)
    (Time.current - days.to_i.days).change(hour: hour, min: (days.to_i * 7) % 60, sec: 0)
  end

  # Map index i in [0, n) to a day offset in [0, 29], deterministically.
  def spread_days(i, n)
    n <= 1 ? 0 : ((i * 29.0) / (n - 1)).round
  end

  # Scale a base count by the city's factor (min 1).
  def scaled(base, city)
    [(base * city[:scale]).round, 1].max
  end

  def upsert_municipality(city)
    Municipality.find_or_create_by!(slug: city[:slug]) do |m|
      m.name = city[:name]
      m.uf = city[:uf]
      m.status = "active"
    end
  end

  # A valid protocol definition (passes Protocols::Validator, same shape as the
  # baseline seed). Recommendations keyed in pt-BR for the public report.
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

  def upsert_protocol(muni, name, version, status)
    ProtocolDefinition.find_or_create_by!(name: name, version: version, municipality_id: muni.id) do |p|
      p.status = status
      p.definition = demo_definition(name, version)
    end
  end

  # Multiple versions/statuses so Protocolos (list, published count, versions
  # detail) is rich. v1 active reuses the baseline row for Curitiba.
  def build_protocols(city, muni)
    resp1 = upsert_protocol(muni, "triage-respiratoria", 1, "active")
    upsert_protocol(muni, "triage-respiratoria", 2, "published")
    upsert_protocol(muni, "triage-respiratoria", 3, "draft")
    dengue1 = upsert_protocol(muni, "triagem-dengue", 1, "active")
    upsert_protocol(muni, "triagem-dengue", 2, "retired")
    { "triage-respiratoria" => resp1, "triagem-dengue" => dengue1 }
  end

  # FSM state distribution (Curitiba base; scaled per city). Covers every funnel
  # bucket (greeting/awaiting_consent/consented), live (awaiting_consent+
  # consented), and exits (revoked). "completed" is a terminal state kept out of
  # the funnel by design.
  STATE_DIST = { "greeting" => 4, "awaiting_consent" => 4, "consented" => 12,
                 "completed" => 8, "revoked" => 3, "abandoned" => 3 }.freeze

  def build_conversations_and_consents(city, muni)
    triage_convos = []
    seq = 0
    STATE_DIST.each do |state, base|
      scaled(base, city).times do
        seq += 1
        phone = format("+55%s9%08d", city[:ddd], seq)
        # Coprime scatter over [0,29]: interleaves states across the whole 30d
        # window (and the 7d sub-window) instead of clustering each state on one
        # day. 13 is coprime with 30 so 34 conversations spread evenly.
        days  = (seq * 13) % 30
        convo = Conversation.find_or_create_by!(municipality_id: muni.id, phone: phone) do |c|
          c.state = state
          c.created_at = at_days_ago(days, hour: 9)
        end

        if %w[consented completed revoked].include?(state)
          version = seq.even? ? 2 : 1
          Consent.where(conversation_id: convo.id).first || Consent.create!(
            conversation: convo, municipality_id: muni.id, version: version,
            channel: "whatsapp", policy_text_sha: "demo-policy-sha-v#{version}",
            given_at: at_days_ago(days, hour: 11),
            revoked_at: (state == "revoked" ? at_days_ago([days - 1, 0].max, hour: 12) : nil)
          )
        end

        triage_convos << { convo: convo, state: state, days: days, seq: seq } if %w[consented completed].include?(state)
      end
    end
    triage_convos
  end

  # Inbound archive + outbound ack log. Inbound spread over 30d (day 0 → <24h
  # pending; days ≥ 2 → >24h backlog/overTtl). Outbound status is a literal
  # 0–5 int: {0,1,2}=ok, {3}=warn, {4,5}=err (ingestion_query.rb:37-42).
  ACK_STATUS_CYCLE = [0, 1, 2, 0, 1, 2, 3, 4, 5, 2, 0, 3, 4].freeze

  def build_ingestion(city, muni)
    n_in = scaled(40, city)
    n_in.times do |i|
      InboundMessage.find_or_create_by!(message_id: "IN-#{city[:code]}-#{format('%04d', i + 1)}") do |m|
        m.from = format("+55%s9%08d", city[:ddd], i + 1)
        m.kind = "text"
        m.municipality_id = muni.id
        m.raw = "demo inbound message #{i + 1}"
        m.created_at = at_days_ago(spread_days(i, n_in), hour: (i % 12) + 8)
      end
    end

    n_out = scaled(30, city)
    n_out.times do |i|
      OutboundMessage.find_or_create_by!(idempotency_key: "OUT-#{city[:code]}-#{format('%04d', i + 1)}") do |m|
        m.to = format("+55%s9%08d", city[:ddd], i + 1)
        m.status = ACK_STATUS_CYCLE[i % ACK_STATUS_CYCLE.length]
        m.template = { "name" => "rota_saude_ask", "language" => { "code" => "pt_BR" } }
        m.municipality_id = muni.id
        m.created_at = at_days_ago(spread_days(i, n_out), hour: (i % 12) + 8)
      end
    end
  end

  TIER_CYCLE = %w[low medium high medium low high medium high].freeze
  MODE_CYCLE = %w[weighted weighted decision_table].freeze
  # Mostly completed, with a few in_progress and aborted for status variety.
  TRIAGE_STATUS_CYCLE = %w[completed completed completed completed in_progress completed aborted_by_timeout completed].freeze

  def build_triages_and_reports(city, muni, citizens, protocols)
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
      priority = tier == "high" ? 1 : 0
      started_at = at_days_ago(days, hour: 9)
      completed_at = completed ? started_at + (3 + (i % 8)).minutes : nil

      triage = Triage.where(conversation_id: convo.id, protocol_definition_id: proto.id).first
      triage ||= Triage.create!(
        conversation: convo, protocol_definition: proto, protocol_name: proto.name,
        municipality_id: muni.id, status: status,
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

      if completed
        expired = (i % 4).zero?
        upsert_report(muni, triage, tier,
                      created_at: completed_at,
                      expires_at: (expired ? at_days_ago(days + 2, hour: 9) : Time.current + 20.days))
      end
    end
    built
  end

  # Build the report snapshot directly (not via GenerateReportJob) so created_at
  # and expires_at can be backdated for a live/expired mix. token/signature per
  # the model contract.
  def upsert_report(muni, triage, tier, created_at:, expires_at:)
    return if ReportSnapshot.where(triage_id: triage.id).exists?
    token = "RPT-#{muni.slug[0, 3].upcase}-#{triage.id.to_s[0, 8]}"
    ReportSnapshot.create!(
      triage: triage, protocol_definition: triage.protocol_definition, municipality_id: muni.id,
      outcome: { "tier" => tier, "priority" => triage.priority, "status" => "terminal" },
      payload: { "tier" => tier, "priority" => triage.priority, "completed_at" => triage.completed_at&.iso8601 },
      token: token, signature: ReportSnapshot.sign(token),
      created_at: created_at, expires_at: expires_at
    )
  end

  # Idempotent by a synthetic payload.demo_id (domain_events has no natural key).
  def upsert_event(demo_id, name:, occurred_at:, municipality_id:, payload:)
    existing = DomainEvent.where("payload ->> 'demo_id' = ?", demo_id).first
    return existing if existing
    DomainEvent.create!(
      name: name, occurred_at: occurred_at, municipality_id: municipality_id,
      published_at: occurred_at, created_at: occurred_at,
      payload: payload.merge("demo_id" => demo_id)
    )
  end

  def build_events(city, muni, protocols, citizens, triages)
    code = city[:code]

    # --- Protocol audit events (Protocolos four-eyes + protocol_events) ---
    # protocols_query matches payload.protocol_definition_id (four_eyes) and
    # payload.name (protocol_events); reads actor + version.
    respv2 = ProtocolDefinition.find_by(name: "triage-respiratoria", version: 2, municipality_id: muni.id)
    dengue1 = protocols["triagem-dengue"]
    dengue2 = ProtocolDefinition.find_by(name: "triagem-dengue", version: 2, municipality_id: muni.id)

    # respiratoria v2: created by A, published by B → fourEyes = true (ok)
    upsert_event("#{code}-P-RESP2-C", name: "protocol.created", occurred_at: at_days_ago(20), municipality_id: muni.id,
                 payload: { "protocol_definition_id" => respv2.id, "name" => "triage-respiratoria", "version" => 2, "actor" => ACTOR_A })
    upsert_event("#{code}-P-RESP2-P", name: "protocol.published", occurred_at: at_days_ago(18), municipality_id: muni.id,
                 payload: { "protocol_definition_id" => respv2.id, "name" => "triage-respiratoria", "version" => 2, "actor" => ACTOR_B })
    # dengue v1: created + published by the SAME actor → fourEyes = false (collapsed)
    upsert_event("#{code}-P-DENG1-C", name: "protocol.created", occurred_at: at_days_ago(25), municipality_id: muni.id,
                 payload: { "protocol_definition_id" => dengue1.id, "name" => "triagem-dengue", "version" => 1, "actor" => ACTOR_A })
    upsert_event("#{code}-P-DENG1-P", name: "protocol.published", occurred_at: at_days_ago(24), municipality_id: muni.id,
                 payload: { "protocol_definition_id" => dengue1.id, "name" => "triagem-dengue", "version" => 1, "actor" => ACTOR_A })
    # dengue v2 retired
    upsert_event("#{code}-P-DENG2-R", name: "protocol.retired", occurred_at: at_days_ago(10), municipality_id: muni.id,
                 payload: { "protocol_definition_id" => dengue2.id, "name" => "triagem-dengue", "version" => 2, "actor" => ACTOR_B })

    # --- conversation.* and consent.* (Events filter prefixes) ---
    citizens.each_with_index do |c, i|
      convo = c[:convo]; days = c[:days]
      upsert_event("#{code}-CV-#{i}", name: "conversation.consented", occurred_at: at_days_ago(days, hour: 10),
                   municipality_id: muni.id, payload: { "conversation_id" => convo.id, "actor" => "sistema" })
      upsert_event("#{code}-CO-#{i}", name: "consent.given", occurred_at: at_days_ago(days, hour: 11),
                   municipality_id: muni.id, payload: { "conversation_id" => convo.id, "actor" => "cidadão" })
    end

    # --- Trail events (BARE names, per completed triage) + prefixed triage/priority ---
    triages.each_with_index do |t, i|
      next unless t[:completed]
      tri = t[:triage]; base = at_days_ago(t[:days], hour: 9)
      upsert_event("#{code}-T-SC-#{i}", name: "scored", occurred_at: base + 1.minute, municipality_id: muni.id,
                   payload: { "triage_id" => tri.id, "rule" => "weighted", "ref" => "mode:#{t[:mode]}", "out" => t[:tier], "actor" => "sistema" })
      upsert_event("#{code}-T-TA-#{i}", name: "tier_assigned", occurred_at: base + 2.minutes, municipality_id: muni.id,
                   payload: { "triage_id" => tri.id, "rule" => "threshold", "ref" => "tier", "out" => t[:tier], "actor" => "sistema" })
      upsert_event("#{code}-T-DONE-#{i}", name: "triage.completed", occurred_at: base + 3.minutes, municipality_id: muni.id,
                   payload: { "triage_id" => tri.id, "actor" => "sistema" })
      next unless t[:priority] == 1
      upsert_event("#{code}-T-PR-#{i}", name: "priority_rule", occurred_at: base + 2.minutes, municipality_id: muni.id,
                   payload: { "triage_id" => tri.id, "rule" => "escalate", "ref" => "priority", "out" => "1", "actor" => "sistema" })
      upsert_event("#{code}-PRI-#{i}", name: "priority.escalated", occurred_at: base + 3.minutes, municipality_id: muni.id,
                   payload: { "triage_id" => tri.id, "actor" => "sistema" })
    end
  end

  def run!
    ApplicationRecord.connected_to(role: :admin) do
      CITIES.each do |city|
        muni = upsert_municipality(city)
        protocols = build_protocols(city, muni)
        citizens = build_conversations_and_consents(city, muni)
        build_ingestion(city, muni)
        triages = build_triages_and_reports(city, muni, citizens, protocols)
        build_events(city, muni, protocols, citizens, triages)
      end
    end
    report_counts
  end

  def report_counts
    ApplicationRecord.connected_to(role: :admin) do
      counts = {
        municipalities: Municipality.where(slug: CITIES.map { |c| c[:slug] }).count
      }
      puts "[dashboard_demo] #{counts.inspect}"
      counts
    end
  end
end

DashboardDemo.run!
