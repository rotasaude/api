require "rails_helper"

# Contratos §3.4 (ADR 0027; spec §5.3): suggested OU available, nunca os dois;
# expiração preguiçosa; contagem agregada de "oferecida".
RSpec.describe Triages::Catalog do
  before { Current.city = TEST_CITY_A }
  after { Current.reset; Rails.cache.clear }

  let(:admin) { staff_with("catalogo-#{SecureRandom.hex(3)}@cidade.gov.br") }
  let!(:respiratoria) { create_default_protocol! }
  let!(:mental) { active_protocol!("saude-mental", offer: { "title" => "Saúde mental" }) }
  let!(:deep) { active_protocol!("saude-mental-aprofundada", offer: { "title" => "Aprofundamento", "summary" => "Mais perguntas." }) }
  let!(:idoso) do
    active_protocol!("saude-do-idoso", offer: { "title" => "Saúde do idoso", "eligibility" => { "gte" => ["profile.age", 60] },
                                                "retake_after_days" => 365 })
  end
  let(:avo) { profiled_citizen!(age: 62) }

  before do
    TriageOffer.create!(protocol_name: "saude-do-idoso", updated_by_user: admin, position: 1)
    TriageOffer.create!(protocol_name: "saude-mental-aprofundada", updated_by_user: admin, position: 2)
  end

  def suggest!(citizen, name, from: "saude-mental")
    TriageSuggestion.create!(citizen: citizen, source_triage: completed_triage!(citizen, from, at: 2.days.ago), protocol_name: name)
  end

  it "monta as três seções na ordem do catálogo, sugestão com a origem" do
    suggestion = suggest!(avo, "saude-mental-aprofundada")
    catalog = described_class.for(citizen: avo)
    expect(catalog[:suggested]).to eq([ {
      protocol_name: "saude-mental-aprofundada", title: "Aprofundamento", summary: "Mais perguntas.",
      suggestion_id: suggestion.id, source_triage_id: suggestion.source_triage_id, source_title: "Saúde mental",
      suggested_on: suggestion.created_at.in_time_zone.to_date.iso8601
    } ])
    expect(catalog[:available].map { |i| i[:protocol_name] }).to eq(%w[saude-do-idoso saude-mental triage-respiratoria])
    expect(catalog[:available].last).to eq(protocol_name: "triage-respiratoria", title: "triage-respiratoria", summary: nil)
    expect(catalog[:recent]).to eq([])
    expect(catalog[:in_progress]).to be_nil
    expect(catalog[:reference_units]).to eq([])
  end

  it "recent traz a última conclusão e a próxima data" do
    completed_triage!(avo, "saude-do-idoso", at: 10.days.ago)
    recent = described_class.for(citizen: avo)[:recent].sole
    last_on = 10.days.ago.to_date
    expect(recent).to eq(protocol_name: "saude-do-idoso", title: "Saúde do idoso", summary: nil,
                         last_completed_on: last_on.iso8601, next_available_on: (last_on + 365).iso8601)
  end

  it "pausa expira a sugestão na leitura" do
    suggestion = suggest!(avo, "saude-mental-aprofundada")
    TriageOffer.find_by!(protocol_name: "saude-mental-aprofundada").update!(enabled: false)
    catalog = described_class.for(citizen: avo)
    expect(catalog[:suggested]).to eq([])
    expect(suggestion.reload).to have_attributes(status: "expired", resolved_at: be_present)
  end

  it "triagem em andamento sai das listas e vem em in_progress" do
    started = start_for!(avo, "saude-mental").payload
    catalog = described_class.for(citizen: avo)
    expect(catalog[:in_progress]).to eq(conversation_id: started[:conversation].id, protocol_name: "saude-mental",
                                        title: "Saúde mental")
    expect(catalog[:available].map { |i| i[:protocol_name] }).not_to include("saude-mental")
  end

  it "conta oferecida por protocolo mostrado, a cada leitura" do
    suggest!(avo, "saude-mental-aprofundada")
    2.times { described_class.for(citizen: avo) }
    expect(TriageOfferDailyCount.where(day: Time.zone.today).order(:protocol_name).pluck(:protocol_name, :offered))
      .to eq([ [ "saude-do-idoso", 2 ], [ "saude-mental", 2 ], [ "saude-mental-aprofundada", 2 ], [ "triage-respiratoria", 2 ] ])
  end

  it "unidades de referência do bairro ATUAL do par" do
    centro = Neighborhood.create!(name: "Centro", source: "seed")
    ubs = create_unit("UBS Centro")
    NeighborhoodCoverage.create!(neighborhood: centro, health_unit: ubs)
    avo.update!(neighborhood: centro)
    expect(described_class.for(citizen: avo)[:reference_units]).to eq(Territory::ReferenceUnits.as_json_list([ ubs ]))
  end

  # "Só por sugestão": fora de "Disponíveis"; aparece em "Sugeridas" quando há
  # sugestão pendente, que não expira por isso. "Oferecida" só conta quando aparece.
  it "protocolo só por sugestão fica fora de Disponíveis e aparece só sugerido" do
    TriageOffer.find_by!(protocol_name: "saude-mental-aprofundada").update!(suggestion_only: true)
    catalog = described_class.for(citizen: avo)
    expect(catalog[:available].map { |i| i[:protocol_name] }).not_to include("saude-mental-aprofundada")
    expect(TriageOfferDailyCount.where(protocol_name: "saude-mental-aprofundada").sum(:offered)).to eq(0)

    suggestion = suggest!(avo, "saude-mental-aprofundada")
    catalog = described_class.for(citizen: avo)
    expect(catalog[:suggested].map { |i| i[:protocol_name] }).to eq(%w[saude-mental-aprofundada])
    expect(suggestion.reload.status).to eq("pending")
    expect(TriageOfferDailyCount.where(protocol_name: "saude-mental-aprofundada").sum(:offered)).to eq(1)
  end

end
