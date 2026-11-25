require "rails_helper"

# Módulo 27b, Task 10 (Valor 7; Q15, Q21): o corpo enviado à BNAFAR. Todas as
# chaves do item sempre presentes; fabricante internacional pelo nome com o
# CNPJ nulo; valor com duas casas; OBM no medicamento e na vacina, CATMAT no
# vetorial.
RSpec.describe Bnafar::Payload, type: :model do
  include ActiveSupport::Testing::TimeHelpers

  before { pharmacy_city! }
  let(:med) { Stock::Domain::MEDICATION }
  let(:central) { central_location!.tap { |location| location.update_columns(cnes: "1234567") } }
  let(:item_keys) do
    %w[codigoOrigem numero terminologia codigoAmpp codigoVmp registroAnvisa tipoProduto lote dataValidade cnpjFabricante
       nomeFabricanteInternacional quantidade valorUnitario siglaProgramaSaude iums]
  end

  def rows(domains: [ med ]) = Bnafar::Snapshot.call(reference_on: Time.zone.today, domains: domains, cutoff: Time.current)

  def position(rows, origin_code: "8f9b6a7e-1111-4222-8333-944455556666")
    described_class.position(cnes: rows.first.cnes, type: rows.first.type, reference_on: Time.zone.today - 1, origin_code: origin_code, rows: rows)
  end

  def med_lot!(**over)
    losartana.update_columns(vmp_code: "@brasil1000")
    bnafar_complete!(stocked_lot!(central, item: losartana, quantity: "30", expires_on: Date.new(2027, 3, 31)), ampp_code: "@brasil20038375080", **over)
  end

  it "item com todas as chaves; iums: []" do
    lot = med_lot!
    body = position(rows)

    expect(body.keys).to eq(%w[estabelecimento caracterizacao itens])
    expect(body["estabelecimento"]).to eq("cnes" => "1234567", "tipo" => "A")
    expect(body["caracterizacao"]).to eq("codigoOrigem" => "8f9b6a7e-1111-4222-8333-944455556666",
                                         "dataPosicaoEstoque" => (Time.zone.today - 1).iso8601)
    item = body["itens"].sole
    expect(item.keys).to eq(item_keys)
    expect(item).to include("codigoOrigem" => lot.id, "lote" => lot.lot_number, "dataValidade" => "2027-03-31", "quantidade" => 30,
                            "registroAnvisa" => "1234567890123", "tipoProduto" => "B", "siglaProgramaSaude" => "AFB",
                            "cnpjFabricante" => bnafar_cnpj, "nomeFabricanteInternacional" => nil, "iums" => [])
  end

  it "IUM do lote vai como [{ ium }]" do
    med_lot!(ium: %w[ABC123 XYZ9])
    expect(position(rows)["itens"].sole["iums"]).to eq([ { "ium" => "ABC123" }, { "ium" => "XYZ9" } ])
  end

  it "internacional → cnpjFabricante: null e o nome" do
    losartana.update_columns(vmp_code: "@brasil1000")
    lot = stocked_lot!(central, item: losartana, quantity: "30")
    bnafar_complete!(lot, manufacturer_cnpj: nil, manufacturer_international: true, manufacturer: "Laboratorios Andinos S.A.",
                          ampp_code: "@brasil20038375080")

    item = position(rows)["itens"].sole
    expect(item.slice("cnpjFabricante", "nomeFabricanteInternacional"))
      .to eq("cnpjFabricante" => nil, "nomeFabricanteInternacional" => "Laboratorios Andinos S.A.")
  end

  it "`valorUnitario` 1990 → 19.90 (número com duas casas, ponto decimal)" do
    med_lot!
    item = position(rows)["itens"].sole
    expect(item["valorUnitario"]).to eq(19.90)
    expect(JSON.generate(item)).to include('"valorUnitario":19.9')
  end

  it "medicamento OBM com numero CATMAT e codigoVmp; vetorial CATMAT; vacina numero: \"\"" do
    lot = med_lot!
    medication = position(rows)["itens"].sole
    expect(medication.slice("numero", "terminologia", "codigoVmp", "codigoAmpp"))
      .to eq("numero" => lot.catmat_code.to_s, "terminologia" => "OBM", "codigoVmp" => "@brasil1000", "codigoAmpp" => "@brasil20038375080")

    place = vector_location!(create_unit("UVZ Payload", kind: "environmental_surveillance", cnes: "4444444"))
    product = vector_product!.tap { |vector| vector.update_columns(catmat_code: 445_566) }
    bnafar_complete!(vector_lot!(place, product: product))
    vector = position(rows(domains: [ Stock::Domain::VECTOR_CONTROL ]))["itens"].sole
    expect(vector.slice("numero", "terminologia", "codigoVmp", "codigoAmpp"))
      .to eq("numero" => "445566", "terminologia" => "CATMAT", "codigoVmp" => nil, "codigoAmpp" => nil)

    yaml = Vaccination::Immunobiologicals.find("15")
    maker = yaml.manufacturers.first
    stubbed = yaml.with(obm_vmp: "@brasil7000", manufacturers: [ maker.with(cnpj: bnafar_cnpj) ])
    allow(Vaccination::Immunobiologicals).to receive(:find).and_call_original
    allow(Vaccination::Immunobiologicals).to receive(:find).with("15").and_return(stubbed)
    cold = cold_chain_central!.tap { |location| location.update_columns(cnes: "2222222") }
    bnafar_complete!(vaccine_lot!(cold, code: "15", doses: 30, manufacturer_key: maker.key), ampp_code: "@brasil70001")
    vaccine = position(rows(domains: [ Stock::Domain::IMMUNOBIOLOGICAL ]))["itens"].sole
    expect(vaccine.slice("numero", "terminologia", "codigoVmp", "cnpjFabricante", "quantidade"))
      .to eq("numero" => "", "terminologia" => "OBM", "codigoVmp" => "@brasil7000", "cnpjFabricante" => bnafar_cnpj, "quantidade" => 3)
  end

  it "posição com dois lotes do item → um item por lote, codigoOrigem = id do lote" do
    first = med_lot!
    second = bnafar_complete!(stocked_lot!(central, item: losartana, quantity: "4"), ampp_code: "@brasil20038375080")

    expect(position(rows)["itens"].map { |item| [ item["codigoOrigem"], item["quantidade"] ] })
      .to contain_exactly([ first.id, 30 ], [ second.id, 4 ])
  end

  it "saída: caracterizacao com dataSaida do dia em que o movimento foi criado, destino e tipo" do
    lot = med_lot!
    created = (Time.zone.today - 1).in_time_zone.change(hour: 23, min: 30)
    movement = travel_to(created) { bnafar_loss!(central, lot, 3, at: created - 2.days) }
    row = Bnafar::Exits.call(day: created.to_date, domains: [ med ], from: created.beginning_of_day, to: created.end_of_day)[:exits].sole

    body = described_class.exit(row, origin_code: "8f9b6a7e-1111-4222-8333-944455556666")
    expect(body["estabelecimento"]).to eq("cnes" => "1234567", "tipo" => "A")
    expect(body["caracterizacao"]).to eq("codigoOrigem" => "8f9b6a7e-1111-4222-8333-944455556666", "dataSaida" => created.to_date.iso8601,
                                         "estabelecimentoDestino" => "1234567", "tipoSaida" => "S-PE")
    item = body["itens"].sole
    expect(item.keys).to eq(item_keys)
    expect(item).to include("codigoOrigem" => movement.id, "quantidade" => 3)
  end
end
