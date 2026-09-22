# GET /admin/api/protocols + /admin/api/protocols/:id (§4.6).
#
# Sinaliza "quatro olhos colapsado" quando created_by == published_by.
# Hoje protocol_definitions NÃO armazena created_by/published_by — esses
# vêm de domain_events (protocol.created / protocol.published). Aproximamos
# pelos eventos quando existirem; null quando não houver dado.
class Admin::ProtocolsQuery
  def self.index
    rows = ProtocolDefinition.all
             .order(:name, version: :desc)
             .map { |d| serialize_row(d, fetch_audit(d)) }
    { list: rows }
  end

  def self.show(id:)
    # id pode ser tanto o `name` quanto um UUID. Tentamos os dois.
    base = ProtocolDefinition.all
    versions = base.where(name: id).order(version: :desc)
    versions = base.where(id: id) if versions.empty?
    return nil if versions.empty?

    first = versions.first
    {
      id: first.name,
      name: first.name,
      versions: versions.map { |d| serialize_version(d, fetch_audit(d)) },
      events: protocol_events(first.name)
    }
  end

  def self.serialize_row(d, audit)
    {
      id: d.name,
      name: d.name,
      version: d.version.to_s,
      status: status_label(d),
      createdBy: audit[:created_by],
      publishedBy: audit[:published_by],
      fourEyes: four_eyes(audit),
      publishedAt: d.activated_at&.iso8601,
      retiredAt: d.retired_at&.iso8601,
      schema: "ok",
      linter: "ok",
      gates: "ok"
    }.merge(signature_state(d))
  end

  def self.serialize_version(d, audit)
    {
      version: d.version.to_s,
      status: status_label(d),
      createdBy: audit[:created_by],
      publishedBy: audit[:published_by],
      fourEyes: four_eyes(audit),
      at: (d.activated_at || d.created_at).iso8601,
      schema: "ok",
      linter: "ok",
      gates: "ok"
    }.merge(signature_state(d))
  end

  # Estado de assinatura de UMA versão (spec de assinaturas §5/§6, ADR-0016, Plano 2
  # Task 5) — fonte de verdade daqui pra frente. createdBy/publishedBy/
  # fourEyes acima (via fetch_audit, de domain_events) ficam como estão só
  # porque o dashboard ainda os lê (Decisão 5 do plano); para "quem assinou o
  # quê", "quem editou" e "dá pra reverter" é ISTO aqui, nunca domain_events —
  # ver o spec que afirma DomainEvent não ser consultado neste método.
  #
  # E-mails em lote: uma única consulta a User para todo signatário válido +
  # todo editor `user` desta versão, nunca uma por assinatura/editor.
  def self.signature_state(d)
    pub_ids = Protocols::Signatures.valid_signer_ids(d, purpose: "publication")
    act_ids = Protocols::Signatures.valid_signer_ids(d, purpose: "activation")
    editor_rows = ProtocolContribution.where(protocol_definition_id: d.id).distinct.pluck(:actor_kind, :actor_id)
    user_editor_ids = editor_rows.select { |kind, _| kind == "user" }.map(&:last)

    emails = User.where(id: (pub_ids + act_ids + user_editor_ids).uniq).pluck(:id, :email_address).to_h

    {
      signatures: {
        publication: signer_block(pub_ids, emails: emails),
        activation: signer_block(act_ids, emails: emails)
      },
      eligibleReviewers: Protocols::Signatures.eligible_reviewer_count(d),
      editors: editor_rows.map { |kind, id| { kind: kind, id: id, email: kind == "user" ? emails[id] : nil } },
      # Mesmas três condições que Protocols::RevertActivation exige para
      # reverter de verdade (controller notes: extrair o predicado em vez de
      # duplicar a lógica) — sem lock, então pode ficar obsoleto assim que
      # outra escrita comita; é leitura de painel, não decisão de escrita.
      revertible: Protocols::RevertActivation.revertible?(d)
    }
  end

  def self.signer_block(ids, emails:)
    {
      signers: ids.map { |id| { id: id, email: emails[id] } },
      missing: [ Protocols::Signatures::REQUIRED - ids.size, 0 ].max
    }
  end

  # `active` costumava virar `published` aqui — colapso que escondia do painel
  # a versão de fato em uso na cidade. A versão `active` é a única que pode
  # ser revertida (Protocols::RevertActivation) e a única que NÃO pode ser
  # aposentada (R4); quem lê precisa distinguir das demais `published`.
  def self.status_label(d)
    case d.status
    when "active"  then "active"
    when "draft"   then "draft"
    when "retired" then "retired"
    else d.status
    end
  end

  def self.four_eyes(audit)
    return nil unless audit[:created_by] && audit[:published_by]
    audit[:created_by] != audit[:published_by]
  end

  # Aproximação: lê os 2 eventos relevantes do agregado. Sem dado clínico.
  # Phase 2.1 dropou aggregate_*; IDs viajam no payload (ADR-0004).
  def self.fetch_audit(d)
    events = DomainEvent.where("payload ->> 'protocol_definition_id' = ?", d.id.to_s)
    {
      created_by: events.find_by(name: "protocol.created")&.payload&.dig("actor"),
      published_by: events.find_by(name: "protocol.published")&.payload&.dig("actor")
    }
  end

  # Os commands de Protocols publicam `protocol_key:`, nunca `name:` — o
  # filtro por `payload ->> 'name'` nunca batia com nada, e a lista de nomes
  # aceitos não incluía os eventos de assinatura (spec de assinaturas §5/§6).
  # Nomes conferidos em app/commands/protocols/*.rb: submissão, assinatura,
  # ativação, reversão, publicação e aposentadoria.
  PROTOCOL_EVENT_NAMES = %w[
    protocol.submitted_for_review
    protocol.signed
    protocol.activated
    protocol.activation_reverted
    protocol.published
    protocol.retired
  ].freeze

  def self.protocol_events(name)
    DomainEvent.where("payload ->> 'protocol_key' = ?", name)
      .where(name: PROTOCOL_EVENT_NAMES)
      .order(occurred_at: :desc)
      .limit(20)
      .map do |ev|
        {
          at: ev.occurred_at.iso8601,
          name: ev.name,
          actor: ev.payload&.dig("actor"),
          ref: "version=#{ev.payload&.dig('version')}"
        }
      end
  end
end
