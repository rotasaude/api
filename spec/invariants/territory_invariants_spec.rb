# Módulo 11, critério de fechamento (ADR 0023; spec 2026-09-28 §7.1). Cada
# bloco tem a mutação que precisa deixá-lo vermelho (registrada no relatório
# da entrega).
require "rails_helper"

RSpec.describe "Invariantes do território (ADR 0023)", type: :request do
  def sql(statement)
    ApplicationRecord.transaction(requires_new: true) { ApplicationRecord.connection.execute(statement) }
  end

  let(:admin) { staff_with("admin@cidade.gov.br", "municipal_admin") }
  let!(:centro) { Neighborhood.create!(name: "Centro", source: "seed") }
  let!(:batel) { Neighborhood.create!(name: "Batel", source: "seed") }

  # Mutação: apagar o bloco DO $do$ de triages_neighborhood_immutable em
  # db/city_triggers.sql, ou afrouxar a exceção (ex.: tirar a condição de
  # status), e recarregar os bancos de teste.
  it "o bairro copiado na triagem só muda para NULL na revogação" do
    triage = territory_triage!(centro)
    expect { sql("UPDATE triages SET neighborhood_id = '#{batel.id}' WHERE id = '#{triage.id}'") }
      .to raise_error(ActiveRecord::StatementInvalid)
    expect { ApplicationRecord.transaction(requires_new: true) { triage.update_columns(neighborhood_id: nil) } }
      .to raise_error(ActiveRecord::StatementInvalid)
    expect(triage.reload.neighborhood_id).to eq(centro.id)

    in_progress = territory_triage!(centro, status: "in_progress")
    expect { in_progress.update_columns(status: "aborted_by_revocation", neighborhood_id: nil) }.not_to raise_error
    expect(in_progress.reload.neighborhood_id).to be_nil
  end

  # Mutação: tirar `neighborhood_id: nil` de AnonymizeRevokedTriageJob.
  it "revogar o consentimento apaga o bairro da triagem" do
    create_default_protocol!
    ConsentTerm.create!(version: "1", body: "Termo", published_at: Time.current)
    citizen = Citizen.create!(cpf: "52998224725", phone: "+5541998765432", neighborhood: centro)
    started = Citizens::StartConversation.call(citizen: citizen, consent_version: "1", session_id: "s").payload
    RevokeConsent.call(conversation: started[:conversation], reason: "citizen_web")
    AnonymizeRevokedTriageJob.new.handle(conversation_id: started[:conversation].id)
    expect(started[:triage].reload).to have_attributes(status: "aborted_by_revocation", neighborhood_id: nil)
  end

  # Mutação: tirar a checagem de ativo de Territory::ReplaceCoverage, ou o
  # `active_neighborhoods` de Citizens::SetNeighborhood.
  it "bairro inativo não entra em cobertura nem no cidadão" do
    inactive = Neighborhood.create!(name: "Ahu", source: "seed", active: false)
    unit = create_unit
    citizen = Citizen.create!(cpf: "52998224725", phone: "+5541998765432")

    expect(Territory::ReplaceCoverage.call(neighborhood: inactive, health_unit_ids: [ unit.id ], by: admin).reason)
      .to eq(:inactive_neighborhood)
    expect(Citizens::SetNeighborhood.call(citizen: citizen, neighborhood_id: inactive.id).reason)
      .to eq(:invalid_neighborhood)
    expect(inactive.coverages).to be_empty
    expect(citizen.reload.neighborhood_id).to be_nil
  end

  # Mutação: tirar `where(active: true)` de Territory::ReferenceUnits.for, ou
  # `health_units: { active: true }` de ids_by_neighborhood.
  it "a unidade de referência nunca inclui unidade inativa" do
    ativa = create_unit("UBS Centro")
    inativa = create_unit("UBS Antiga", active: false)
    [ ativa, inativa ].each { |u| NeighborhoodCoverage.create!(neighborhood: centro, health_unit: u) }

    expect(Territory::ReferenceUnits.for(centro.id)).to eq([ ativa ])
    expect(Territory::ReferenceUnits.ids_by_neighborhood([ centro.id ])).to eq(centro.id => [ ativa.id ])
  end

  # Decisão do usuário (2026-09-28, posterior ao brief): reference_unit_ids de
  # uma linha da fila nunca inclui a própria unidade do atendimento.
  # Mutação: tirar `- [ a.health_unit_id ]` de AttendancesController#queue_json.
  it "reference_unit_ids da fila nunca inclui a própria unidade do atendimento" do
    verifier = staff_with("atendente@cidade.gov.br", "citizen_verifier")
    unit = create_unit("UBS Centro")
    outra = create_unit("UBS Sul")
    [ unit, outra ].each { |u| NeighborhoodCoverage.create!(neighborhood: centro, health_unit: u) }
    citizen = Citizen.create!(cpf: "52998224725", phone: "+5541998765432", neighborhood: centro)
    waiting = waiting_attendance(citizen, unit: unit, by: verifier)

    sign_in_as(verifier)
    get "/attendance/units/#{unit.id}/queue"
    ids = JSON.parse(response.body)["waiting"].sole["reference_unit_ids"]
    expect(ids).to eq([ outra.id ])
    expect(ids).not_to include(unit.id)
    expect(waiting.id).to be_present # sanity: a linha existe de fato
  end

  # Decisão do usuário (2026-09-28, posterior ao brief): o relatório público
  # (GET /r/:token, sem login) nunca traz reference_units nem dado de bairro.
  # Mutação: acrescentar reference_units (ou o nome/id do bairro) ao JSON de
  # ReportsController#show.
  it "o relatório público nunca traz reference_units nem bairro" do
    create_default_protocol!
    ConsentTerm.create!(version: "1", body: "Termo", published_at: Time.current)
    ubs = create_unit("UBS Centro")
    NeighborhoodCoverage.create!(neighborhood: centro, health_unit: ubs)
    sign_in_citizen("+5541998765432")
    json_post "/citizen/conversations", cpf: "529.982.247-25", consent_version: "1", neighborhood_id: centro.id
    triage_id = JSON.parse(response.body).dig("step", "triage_id")
    triage = Triage.find(triage_id)
    token = ReportSnapshot.mint_token
    ReportSnapshot.create!(triage: triage, protocol_definition: triage.protocol_definition,
                           outcome: { "tier" => "alta" }, payload: { "tier" => "alta", "priority" => 1 },
                           token: token, signature: ReportSnapshot.sign(token), expires_at: 30.days.from_now)

    get "/r/#{token}"
    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body).keys).not_to include("reference_units", "neighborhood", "neighborhood_id")
    expect(response.body).not_to match(/reference_units|neighborhood/)
    expect(response.body).not_to include(centro.id, "Centro", ubs.id, "UBS Centro")
  end

  # Mutação: tirar qualquer @filter.count / series / over / share / list de
  # uma das cinco queries (uma por vez).
  describe "com filtro, nenhum dos cinco painéis devolve número de 1 a 4" do
    panels = %w[overview classification triages reports conversations]
    # Não são contagens: régua do protocolo e prioridade clínica da amostra.
    non_count_keys = %w[urgentMaxPriority priority]

    small_numbers = lambda do |node, path = "$"|
      case node
      when Hash
        node.flat_map { |k, v| non_count_keys.include?(k) ? [] : small_numbers.call(v, "#{path}.#{k}") }
      when Array
        node.each_with_index.flat_map { |v, i| small_numbers.call(v, "#{path}[#{i}]") }
      when Numeric
        (1..4).cover?(node) ? [ "#{path}=#{node}" ] : []
      else
        []
      end
    end

    before do
      3.times { territory_report!(territory_triage!(batel)) }
      6.times { territory_report!(territory_triage!(centro)) }
      territory_report!(territory_triage!(centro, tier: "baixa", priority: 9))
      2.times { territory_report!(territory_triage!(nil)) }
      Conversation.create!(phone: "+5541911110000", state: "consented") # WhatsApp, sem cidadão
      sign_in_as(staff_with("viewer@cidade.gov.br", "viewer"))
    end

    it "a varredura acha número pequeno sem filtro (prova que a fixture o exercita)" do
      get "/admin/api/classification", params: { period: "7d" }
      expect(small_numbers.call(JSON.parse(response.body)["data"])).not_to be_empty
    end

    { "bairro com 3 casos" => :batel, "bairro com 7 casos, um deles único na categoria" => :centro,
      "sem bairro" => nil }.each do |label, which|
      it "#{label}: nenhum número de 1 a 4" do
        param = which ? public_send(which).id : "none"
        offenders = panels.flat_map do |panel|
          get "/admin/api/#{panel}", params: { period: "7d", neighborhood_id: param }
          expect(response).to have_http_status(:ok), panel
          small_numbers.call(JSON.parse(response.body)["data"], panel)
        end
        expect(offenders).to eq([])
      end
    end

    # O cenário acima usa um único protocolo (um só modo de scoring), então
    # byMode nunca tem mais de uma categoria e a mutação-alvo do Passo 3 (tirar
    # @filter.share de by_mode) não apareceria: com uma categoria só, o share
    # sempre é 100. Este caso cria uma segunda categoria minoritária (1 em 25)
    # cujo share vazado (4%) cai em 1-4 se a supressão for removida.
    # Mutação: tirar `@filter.share(count, total, share)` de
    # Admin::ClassificationQuery#by_mode.
    it "share da categoria minoritária de modo some junto com a contagem" do
      outro = ProtocolDefinition.create!(
        name: "outro-protocolo-territorio", version: 1, status: "active",
        definition: {
          "name" => "outro-protocolo-territorio", "version" => 1, "start_step_id" => "unico",
          "steps" => [ { "id" => "unico", "prompt" => "?", "answer_type" => "boolean",
                        "branches" => { "true" => nil, "false" => nil }, "weights" => { "true" => 1, "false" => 0 } } ],
          "scoring" => { "type" => "outro_modo", "thresholds" => { "baixa" => 0 }, "priority_map" => { "baixa" => 9 } }
        }
      )
      minoritaria = territory_triage!(centro)
      minoritaria.update_columns(protocol_definition_id: outro.id, protocol_name: outro.name)
      24.times { territory_triage!(centro) }

      sign_in_as(staff_with("viewer2@cidade.gov.br", "viewer"))
      get "/admin/api/classification", params: { period: "7d", neighborhood_id: centro.id }
      by_mode = JSON.parse(response.body).dig("data", "byMode")
      row = by_mode.find { |r| r["mode"] == "outro_modo" }
      expect(row["count"]).to eq("suppressed" => true)
      expect(row["share"]).to eq("suppressed" => true)
    end

    # O cenário compartilhado usa 5 minutos fixos (territory_triage!), fora de
    # 1-4: a mutação-alvo do Passo 3 (tirar @filter.over de
    # avg_complete_minutes) não vazaria um número pequeno ali. Aqui o total
    # filtrado é pequeno (3, como "bairro com 3 casos") e a média é forçada
    # para 3 minutos, um valor que cai em 1-4 se a supressão for removida.
    # Mutação: tirar `@filter.over(total, ...)` de
    # Admin::ConversationsQuery#avg_complete_minutes.
    it "média de conclusão some quando o total do bairro é pequeno" do
      pequeno = Neighborhood.create!(name: "Pequeno", source: "seed")
      3.times { territory_triage!(pequeno) }
      Triage.where(neighborhood_id: pequeno.id).update_all("completed_at = created_at + interval '3 minutes'")

      sign_in_as(staff_with("viewer3@cidade.gov.br", "viewer"))
      get "/admin/api/conversations", params: { period: "7d", neighborhood_id: pequeno.id }
      expect(JSON.parse(response.body).dig("data", "avgToCompleteMin")).to eq("suppressed" => true)
    end
  end

  # Mutação: fazer Territory::Seed casar pelo nome em vez da seed_key, atualizar
  # o bairro existente (ex.: `active: true`) ou recriar a cobertura.
  it "a semente é idempotente e não desfaz edição (nem renomear)" do
    unit = create_unit("UBS Centro")
    dir = Pathname(Dir.mktmpdir)
    path = dir.join("cidade.yml")
    path.write("neighborhoods:\n  - name: Portão\n    key: portao\n    units: [\"UBS Centro\"]\n  - name: Ahú\n    key: ahu\n    units: [\"UBS Centro\"]\n")

    Territory::Seed.call(path: path)
    snapshot = -> { [ Neighborhood.order(:name).pluck(:name, :active, :source), NeighborhoodCoverage.count ] }
    before = snapshot.call
    Territory::Seed.call(path: path)
    expect(snapshot.call).to eq(before)

    portao = Neighborhood.named("Portão").sole
    ahu = Neighborhood.named("Ahú").sole
    Territory::SetNeighborhoodActive.call(neighborhood: portao, active: false, by: admin)
    Territory::RenameNeighborhood.call(neighborhood: portao, name: "Portão Velho", by: admin)
    Territory::ReplaceCoverage.call(neighborhood: ahu, health_unit_ids: [], by: admin)
    Territory::Seed.call(path: path)

    expect(Neighborhood.count).to eq(before.first.size)
    expect(portao.reload).to have_attributes(name: "Portão Velho", active: false)
    expect(ahu.reload.coverages).to be_empty
    expect(unit.reload).to be_active
  ensure
    FileUtils.remove_entry(dir) if dir
  end

  # Mutação: pôr uma URL do serviço de CEP em qualquer arquivo de app/.
  it "o api nunca chama serviço de CEP" do
    offenders = Dir[Rails.root.join("{app,lib,config,db}/**/*").to_s].select do |path|
      File.file?(path) && File.binread(path).match?(/viacep/i)
    end
    expect(offenders).to eq([])
  end

  # Mutação: pôr `name: neighborhood.name` no payload de neighborhood.created,
  # ou `cpf: citizen.cpf` no de citizen.neighborhood_changed.
  it "eventos do território carregam só ids" do
    unit = create_unit("UBS Centro")
    citizen = Citizen.create!(cpf: "52998224725", phone: "+5541998765432")
    created = Territory::CreateNeighborhood.call(name: "Santa Felicidade", by: admin).payload[:neighborhood]
    Territory::RenameNeighborhood.call(neighborhood: created, name: "Santa Felicidade Velha", by: admin)
    Territory::ReplaceCoverage.call(neighborhood: created, health_unit_ids: [ unit.id ], by: admin)
    Territory::SetNeighborhoodActive.call(neighborhood: batel, active: false, by: admin)
    Territory::SetNeighborhoodActive.call(neighborhood: batel, active: true, by: admin)
    Citizens::SetNeighborhood.call(citizen: citizen, neighborhood_id: created.id)

    payloads = DomainEvent.where("name LIKE 'neighborhood.%' OR name = 'citizen.neighborhood_changed'")
                          .map { |e| e.payload.to_json }
    expect(payloads.size).to eq(6)
    [ "Santa Felicidade", "Batel", "UBS Centro", citizen.cpf, citizen.phone ].each do |secret|
      expect(payloads).to all(satisfy { |p| !p.include?(secret) }), "vazou #{secret}"
    end
  end
end
